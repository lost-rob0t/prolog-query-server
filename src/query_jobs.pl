:- module(query_jobs,
          [ submit_query/4,
            query_status/2,
            cancel_query/2,
            reset_jobs/0
          ]).

:- use_module(library(uuid)).
:- use_module(config).
:- use_module(kb_service).
:- use_module(metrics, [observe_query/2, observe_error/1, observe_refresh/1]).
:- use_module(api_errors).

:- dynamic query_job/7.

% query_job(QueryId, State, ThreadId, CreatedAt, FinishedAt, Result, ErrorPayload).

submit_query(KB, Goal, Options0, Ack) :-
    new_query_id(QueryId),
    get_time(CreatedAt),
    reserve_job(QueryId, CreatedAt),
    Options = [query_id(QueryId)|Options0],
    catch(thread_create(query_worker(QueryId, KB, Goal, Options),
                        _Thread,
                        [detached(true)]),
          Error,
          ( remove_job(QueryId),
            throw(Error)
          )),
    Ack = _{query_id:QueryId, status:"queued"}.

query_status(QueryId, Status) :-
    cleanup_terminal_jobs,
    with_mutex(pqs_query_jobs,
               (   query_job(QueryId,
                             State,
                             _Thread,
                             _CreatedAt,
                             _FinishedAt,
                             Result,
                             ErrorPayload)
               ->  public_status(QueryId, State, Result, ErrorPayload, Status)
               ;   throw(error(pqs_query_not_found(QueryId), _))
               )).

cancel_query(QueryId, Reply) :-
    cleanup_terminal_jobs,
    with_mutex(pqs_query_jobs, cancellation_target(QueryId, Target)),
    cancel_target(Target, QueryId, Reply).

reset_jobs :-
    with_mutex(pqs_query_jobs,
               retractall(query_job(_, _, _, _, _, _, _))).

new_query_id(QueryId) :-
    uuid(UUID, [version(4)]),
    atom_string(UUID, QueryId).

reserve_job(QueryId, CreatedAt) :-
    cleanup_terminal_jobs,
    config:max_active_queries(MaxActive),
    with_mutex(pqs_query_jobs,
               ( active_job_count(Active),
                 (   Active < MaxActive
                 ->  assertz(query_job(QueryId,
                                       queued,
                                       none,
                                       CreatedAt,
                                       none,
                                       none,
                                       none))
                 ;   throw(error(pqs_resource_limit(active_queries,
                                                    _{max_active_queries:MaxActive,
                                                      active_queries:Active}),
                                      _))
                 )
               )).

active_job_count(Count) :-
    findall(1,
            ( query_job(_, State, _, _, _, _, _),
              active_state(State)
            ),
            Active),
    length(Active, Count).

active_state(queued).
active_state(running).
active_state(cancelling).

terminal_state(completed).
terminal_state(failed).
terminal_state(cancelled).

cleanup_terminal_jobs :-
    get_time(Now),
    config:query_result_ttl_seconds(TTL),
    with_mutex(pqs_query_jobs,
               forall(( query_job(QueryId,
                                  State,
                                  Thread,
                                  CreatedAt,
                                  FinishedAt,
                                  Result,
                                  ErrorPayload),
                        terminal_state(State),
                        number(FinishedAt),
                        Age is Now - FinishedAt,
                        Age > TTL
                      ),
                      retract(query_job(QueryId,
                                        State,
                                        Thread,
                                        CreatedAt,
                                        FinishedAt,
                                        Result,
                                        ErrorPayload)))).

remove_job(QueryId) :-
    with_mutex(pqs_query_jobs,
               retractall(query_job(QueryId, _, _, _, _, _, _))).

query_worker(QueryId, KB, Goal, Options) :-
    thread_self(Thread),
    catch(( mark_running(QueryId, Thread),
            % A cancellation signal may arrive during CouchDB refresh as well as
            % inference. Keep every dynamic runtime mutation isolated until the
            % whole query succeeds; an exception rolls the refresh back atomically.
            transaction(kb_service:query_kb(KB, Goal, Options, Result)),
            metrics:observe_query(Result, Options),
            observe_result_refresh(Result),
            finish_success(QueryId, Result)
          ),
          Error,
          finish_error(QueryId, Error)).

mark_running(QueryId, Thread) :-
    with_mutex(pqs_query_jobs,
               ( query_job(QueryId,
                           State,
                           _OldThread,
                           CreatedAt,
                           none,
                           none,
                           none)
               -> mark_running_state(State, QueryId, Thread, CreatedAt)
               ;  throw(error(pqs_query_cancelled(QueryId), _))
               )).

mark_running_state(queued, QueryId, Thread, CreatedAt) :-
    retract(query_job(QueryId, queued, _, CreatedAt, none, none, none)),
    assertz(query_job(QueryId, running, Thread, CreatedAt, none, none, none)).
mark_running_state(cancelling, QueryId, _Thread, _CreatedAt) :-
    throw(error(pqs_query_cancelled(QueryId), _)).
mark_running_state(State, QueryId, _Thread, _CreatedAt) :-
    throw(error(pqs_query_not_cancellable(QueryId, State), _)).

observe_result_refresh(Result) :-
    (   get_dict(refresh, Result, Refresh)
    ->  metrics:observe_refresh(Refresh)
    ;   true
    ).

finish_success(QueryId, Result) :-
    get_time(FinishedAt),
    with_mutex(pqs_query_jobs,
               (   retract(query_job(QueryId,
                                     State,
                                     Thread,
                                     CreatedAt,
                                     none,
                                     none,
                                     none))
               ->  finish_success_state(State,
                                        QueryId,
                                        Thread,
                                        CreatedAt,
                                        FinishedAt,
                                        Result)
               ;   true
               )).

finish_success_state(cancelling,
                     QueryId,
                     Thread,
                     CreatedAt,
                     FinishedAt,
                     _Result) :-
    !,
    assertz(query_job(QueryId,
                      cancelled,
                      Thread,
                      CreatedAt,
                      FinishedAt,
                      none,
                      _{error:"query_cancelled", query_id:QueryId})).
finish_success_state(_State,
                     QueryId,
                     Thread,
                     CreatedAt,
                     FinishedAt,
                     Result) :-
    assertz(query_job(QueryId,
                      completed,
                      Thread,
                      CreatedAt,
                      FinishedAt,
                      Result,
                      none)).

finish_error(QueryId, Error) :-
    metrics:observe_error(Error),
    api_errors:error_payload(Error, Payload),
    get_time(FinishedAt),
    error_terminal_state(Error, TerminalState),
    with_mutex(pqs_query_jobs,
               (   retract(query_job(QueryId,
                                     _State,
                                     Thread,
                                     CreatedAt,
                                     none,
                                     none,
                                     none))
               ->  assertz(query_job(QueryId,
                                      TerminalState,
                                      Thread,
                                      CreatedAt,
                                      FinishedAt,
                                      none,
                                      Payload))
               ;   true
               )).

error_terminal_state(error(pqs_query_cancelled(_), _), cancelled) :- !.
error_terminal_state(_Error, failed).

cancellation_target(QueryId, Target) :-
    (   query_job(QueryId,
                  State,
                  Thread,
                  CreatedAt,
                  FinishedAt,
                  Result,
                  ErrorPayload)
    ->  cancellation_state(State,
                           QueryId,
                           Thread,
                           CreatedAt,
                           FinishedAt,
                           Result,
                           ErrorPayload,
                           Target)
    ;   throw(error(pqs_query_not_found(QueryId), _))
    ).

cancellation_state(queued,
                   QueryId,
                   Thread,
                   CreatedAt,
                   none,
                   none,
                   none,
                   target(Thread)) :-
    !,
    retract(query_job(QueryId, queued, Thread, CreatedAt, none, none, none)),
    assertz(query_job(QueryId, cancelling, Thread, CreatedAt, none, none, none)).
cancellation_state(running,
                   QueryId,
                   Thread,
                   CreatedAt,
                   none,
                   none,
                   none,
                   target(Thread)) :-
    !,
    retract(query_job(QueryId, running, Thread, CreatedAt, none, none, none)),
    assertz(query_job(QueryId, cancelling, Thread, CreatedAt, none, none, none)).
cancellation_state(cancelling,
                   _QueryId,
                   _Thread,
                   _CreatedAt,
                   _FinishedAt,
                   _Result,
                   _ErrorPayload,
                   already_cancelling) :-
    !.
cancellation_state(State,
                   QueryId,
                   _Thread,
                   _CreatedAt,
                   _FinishedAt,
                   _Result,
                   _ErrorPayload,
                   _Target) :-
    throw(error(pqs_query_not_cancellable(QueryId, State), _)).

cancel_target(already_cancelling, QueryId,
              _{query_id:QueryId, status:"cancelling"}) :- !.
cancel_target(target(none), QueryId,
              _{query_id:QueryId, status:"cancelling"}) :- !.
cancel_target(target(Thread), QueryId, Reply) :-
    catch(thread_signal(Thread,
                        throw(error(pqs_query_cancelled(QueryId), _))),
          SignalError,
          cancel_signal_race(QueryId, SignalError)),
    Reply = _{query_id:QueryId, status:"cancelling"}.

cancel_signal_race(QueryId, _SignalError) :-
    with_mutex(pqs_query_jobs,
               (   query_job(QueryId, State, _, _, _, _, _)
               ->  ( terminal_state(State)
                   -> true
                   ;  throw(error(pqs_query_not_cancellable(QueryId, State), _))
                   )
               ;   throw(error(pqs_query_not_found(QueryId), _))
               )).

public_status(QueryId, queued, _Result, _Error,
              _{query_id:QueryId, status:"queued"}).
public_status(QueryId, running, _Result, _Error,
              _{query_id:QueryId, status:"running"}).
public_status(QueryId, cancelling, _Result, _Error,
              _{query_id:QueryId, status:"cancelling"}).
public_status(QueryId, completed, Result, _Error,
              _{query_id:QueryId, status:"completed", result:Result}).
public_status(QueryId, cancelled, _Result, _Error,
              _{query_id:QueryId, status:"cancelled"}).
public_status(QueryId, failed, _Result, ErrorPayload, Status) :-
    put_dict(_{query_id:QueryId, status:"failed"}, ErrorPayload, Status).
