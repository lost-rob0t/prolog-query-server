:- module(metrics,
          [ reset_metrics/0,
            observe_http/3,
            observe_query/2,
            observe_refresh/1,
            observe_error/1,
            increment_knowledge_write/1,
            prometheus_text/1,
            snapshot/1
          ]).

:- use_module(library(lists)).
:- use_module(library(option)).

:- dynamic metric_counter/3.
:- dynamic metric_sum/3.
:- dynamic metric_gauge/3.

reset_metrics :-
    with_mutex(pqs_metrics,
               ( retractall(metric_counter(_, _, _)),
                 retractall(metric_sum(_, _, _)),
                 retractall(metric_gauge(_, _, _))
               )).

observe_http(Endpoint, Outcome, DurationSeconds) :-
    with_mutex(pqs_metrics,
               ( increment_counter(http_requests, endpoint_outcome(Endpoint, Outcome), 1),
                 increment_counter(http_duration_count, endpoint(Endpoint), 1),
                 increment_sum(http_duration_sum, endpoint(Endpoint), DurationSeconds)
               )).

observe_query(Result, Options) :-
    get_dict(count, Result, Count),
    option(max_solutions(MaxSolutions), Options, 100),
    solution_limit_hit(Result, Count, MaxSolutions, SolutionLimitHit),
    depth_limit_hit(Result, DepthLimitHit),
    with_mutex(pqs_metrics,
               ( increment_counter(query_requests, all, 1),
                 increment_counter(query_solutions, all, Count),
                 set_gauge(query_last_solutions, all, Count),
                 set_gauge(query_max_solutions_configured, all, MaxSolutions),
                 observe_limit_hit(SolutionLimitHit, query_solution_limit_hits),
                 observe_limit_hit(DepthLimitHit, query_depth_limit_hits)
               )).

solution_limit_hit(Result, _Count, _MaxSolutions, Hit) :-
    get_dict(limit_hits, Result, Limits),
    is_dict(Limits),
    get_dict(max_solutions, Limits, Hit),
    !.
solution_limit_hit(_Result, Count, MaxSolutions, Hit) :-
    ( Count >= MaxSolutions -> Hit = true ; Hit = false ).

depth_limit_hit(Result, Hit) :-
    get_dict(limit_hits, Result, Limits),
    is_dict(Limits),
    get_dict(max_depth, Limits, Hit),
    !.
depth_limit_hit(_Result, false).

observe_limit_hit(true, Counter) :-
    !,
    increment_counter(Counter, all, 1).
observe_limit_hit(_Hit, _Counter).

observe_refresh(Refresh) :-
    (   is_dict(Refresh),
        get_dict(sync_mode, Refresh, Mode)
    ->  refresh_metrics(Mode, Refresh)
    ;   true
    ).

refresh_metrics("full", Refresh) :-
    !,
    (get_dict(documents, Refresh, Documents) -> true ; Documents = 0),
    with_mutex(pqs_metrics,
               ( increment_counter(kb_full_reloads, all, 1),
                 set_gauge(kb_last_snapshot_documents, all, Documents)
               )).
refresh_metrics("changes", Refresh) :-
    !,
    (get_dict(changes_seen, Refresh, Seen) -> true ; Seen = 0),
    (get_dict(knowledge_applied, Refresh, Applied) -> true ; Applied = 0),
    (get_dict(knowledge_removed, Refresh, Removed) -> true ; Removed = 0),
    with_mutex(pqs_metrics,
               ( increment_counter(kb_changes_syncs, all, 1),
                 increment_counter(kb_changes_seen, all, Seen),
                 increment_counter(kb_changes_applied, all, Applied),
                 increment_counter(kb_changes_removed, all, Removed),
                 set_gauge(kb_last_changes_seen, all, Seen)
               )).
refresh_metrics(_Mode, _Refresh).

observe_error(Error) :-
    with_mutex(pqs_metrics,
               ( increment_counter(api_errors, all, 1),
                 classify_error(Error, Class),
                 increment_counter(error_class, Class, 1),
                 observe_couchdb_error(Error),
                 observe_resource_error(Error)
               )).

observe_couchdb_error(error(couchdb_error(409, _), _)) :-
    !,
    increment_counter(couchdb_conflicts, all, 1),
    increment_counter(couchdb_errors, all, 1).
observe_couchdb_error(error(couchdb_error(_, _), _)) :-
    !,
    increment_counter(couchdb_errors, all, 1).
observe_couchdb_error(_).

observe_resource_error(error(pqs_query_resource(query_timeout, _, _), _)) :-
    !,
    increment_counter(query_timeouts, all, 1).
observe_resource_error(error(pqs_query_resource(inference_budget, _, _), _)) :-
    !,
    increment_counter(query_inference_limit_hits, all, 1).
observe_resource_error(error(pqs_query_resource(proof_limit, _, _), _)) :-
    !,
    increment_counter(query_proof_limit_hits, all, 1).
observe_resource_error(error(pqs_query_cancelled(_), _)) :-
    !,
    increment_counter(query_cancellations, all, 1).
observe_resource_error(error(pqs_resource_limit(request_size, _), _)) :-
    !,
    increment_counter(request_size_rejections, all, 1).
observe_resource_error(error(pqs_resource_limit(document_size, _), _)) :-
    !,
    increment_counter(kb_size_rejections, all, 1).
observe_resource_error(error(pqs_resource_limit(kb_document_count, _), _)) :-
    !,
    increment_counter(kb_size_rejections, all, 1).
observe_resource_error(error(pqs_resource_limit(kb_size, _), _)) :-
    !,
    increment_counter(kb_size_rejections, all, 1).
observe_resource_error(error(pqs_resource_limit(rule_goal_count, _), _)) :-
    !,
    increment_counter(kb_size_rejections, all, 1).
observe_resource_error(_).

increment_knowledge_write(Kind) :-
    with_mutex(pqs_metrics,
               increment_counter(knowledge_writes, Kind, 1)).

classify_error(error(permission_error(access, api_authentication, _), _), authentication) :- !.
classify_error(error(permission_error(access, api_capability, _), _), authorization) :- !.
classify_error(error(couchdb_error(409, _), _), couchdb_conflict) :- !.
classify_error(error(couchdb_error(_, _), _), couchdb) :- !.
classify_error(error(permission_error(activate, invalid_knowledge_release, _), _), invalid_release) :- !.
classify_error(error(pqs_query_resource(query_timeout, _, _), _), query_timeout) :- !.
classify_error(error(pqs_query_resource(inference_budget, _, _), _), inference_budget) :- !.
classify_error(error(pqs_query_resource(proof_limit, _, _), _), proof_limit) :- !.
classify_error(error(pqs_query_cancelled(_), _), query_cancelled) :- !.
classify_error(error(pqs_resource_limit(request_size, _), _), request_size) :- !.
classify_error(error(pqs_resource_limit(_, _), _), resource_limit) :- !.
classify_error(error(domain_error(_, _), _), domain) :- !.
classify_error(error(type_error(_, _), _), type) :- !.
classify_error(_, other).

increment_counter(Name, Labels, Amount) :-
    (   retract(metric_counter(Name, Labels, Existing))
    ->  Value is Existing + Amount
    ;   Value = Amount
    ),
    assertz(metric_counter(Name, Labels, Value)).

increment_sum(Name, Labels, Amount) :-
    (   retract(metric_sum(Name, Labels, Existing))
    ->  Value is Existing + Amount
    ;   Value = Amount
    ),
    assertz(metric_sum(Name, Labels, Value)).

set_gauge(Name, Labels, Value) :-
    retractall(metric_gauge(Name, Labels, _)),
    assertz(metric_gauge(Name, Labels, Value)).

snapshot(Snapshot) :-
    with_mutex(pqs_metrics,
               ( findall(_{name:Name, labels:Labels, value:Value},
                         metric_counter(Name, Labels, Value), Counters),
                 findall(_{name:Name, labels:Labels, value:Value},
                         metric_sum(Name, Labels, Value), Sums),
                 findall(_{name:Name, labels:Labels, value:Value},
                         metric_gauge(Name, Labels, Value), Gauges)
               )),
    Snapshot = _{counters:Counters, sums:Sums, gauges:Gauges}.

prometheus_text(Text) :-
    with_mutex(pqs_metrics,
               findall(Line,
                       prometheus_line(Line),
                       Lines)),
    atomic_list_concat(Lines, '\n', Body),
    (   Body == ''
    ->  Text = '# prolog-query-server metrics\n'
    ;   format(atom(Text), '# prolog-query-server metrics~n~w~n', [Body])
    ).

prometheus_line(Line) :-
    metric_counter(Name, Labels, Value),
    counter_metric(Name, Metric, Help),
    metric_line(Metric, Labels, Value, Help, Line).
prometheus_line(Line) :-
    metric_sum(Name, Labels, Value),
    sum_metric(Name, Metric, Help),
    metric_line(Metric, Labels, Value, Help, Line).
prometheus_line(Line) :-
    metric_gauge(Name, Labels, Value),
    gauge_metric(Name, Metric, Help),
    metric_line(Metric, Labels, Value, Help, Line).

metric_line(Metric, Labels, Value, _Help, Line) :-
    label_text(Labels, LabelText),
    format(atom(Line), '~w~w ~16g', [Metric, LabelText, Value]).

counter_metric(http_requests, 'pqs_http_requests_total', 'HTTP requests by endpoint and outcome').
counter_metric(http_duration_count, 'pqs_http_request_duration_seconds_count', 'Observed HTTP request durations').
counter_metric(query_requests, 'pqs_query_requests_total', 'Expert-system queries').
counter_metric(query_solutions, 'pqs_query_solutions_total', 'Expert-system solutions returned').
counter_metric(query_solution_limit_hits, 'pqs_query_solution_limit_hits_total', 'Queries reaching configured solution limit').
counter_metric(query_depth_limit_hits, 'pqs_query_depth_limit_hits_total', 'Queries pruning at configured inference depth').
counter_metric(query_timeouts, 'pqs_query_timeouts_total', 'Queries terminated by wall-clock deadline').
counter_metric(query_cancellations, 'pqs_query_cancellations_total', 'Queries cooperatively cancelled').
counter_metric(query_inference_limit_hits, 'pqs_query_inference_limit_hits_total', 'Queries exhausting inference-step budget').
counter_metric(query_proof_limit_hits, 'pqs_query_proof_limit_hits_total', 'Queries exhausting proof output budget').
counter_metric(kb_size_rejections, 'pqs_kb_size_rejections_total', 'Knowledge documents or snapshots rejected by resource limits').
counter_metric(request_size_rejections, 'pqs_request_size_rejections_total', 'HTTP request bodies rejected by size limit').
counter_metric(kb_full_reloads, 'pqs_kb_full_reloads_total', 'Full CouchDB knowledge snapshot reloads').
counter_metric(kb_changes_syncs, 'pqs_kb_changes_syncs_total', 'Incremental CouchDB changes synchronizations').
counter_metric(kb_changes_seen, 'pqs_kb_changes_seen_total', 'CouchDB changes observed').
counter_metric(kb_changes_applied, 'pqs_kb_changes_applied_total', 'Knowledge changes applied to Prolog runtime').
counter_metric(kb_changes_removed, 'pqs_kb_changes_removed_total', 'Knowledge clauses removed from Prolog runtime').
counter_metric(api_errors, 'pqs_api_errors_total', 'API errors').
counter_metric(error_class, 'pqs_error_class_total', 'API errors by coarse class').
counter_metric(couchdb_errors, 'pqs_couchdb_errors_total', 'CouchDB errors observed by API').
counter_metric(couchdb_conflicts, 'pqs_couchdb_conflicts_total', 'CouchDB revision conflicts').
counter_metric(knowledge_writes, 'pqs_knowledge_writes_total', 'Knowledge mutation operations').

sum_metric(http_duration_sum, 'pqs_http_request_duration_seconds_sum', 'Total observed HTTP request duration').

gauge_metric(query_last_solutions, 'pqs_query_last_solutions', 'Solutions returned by most recent query').
gauge_metric(query_max_solutions_configured, 'pqs_query_max_solutions_configured', 'Max solutions configured for most recent query').
gauge_metric(kb_last_snapshot_documents, 'pqs_kb_last_snapshot_documents', 'Documents in most recent full KB snapshot').
gauge_metric(kb_last_changes_seen, 'pqs_kb_last_changes_seen', 'Changes seen in most recent incremental sync').

label_text(all, '').
label_text(endpoint(Endpoint), Text) :-
    safe_label(Endpoint, EndpointText),
    format(atom(Text), '{endpoint="~w"}', [EndpointText]).
label_text(endpoint_outcome(Endpoint, Outcome), Text) :-
    safe_label(Endpoint, EndpointText),
    safe_label(Outcome, OutcomeText),
    format(atom(Text), '{endpoint="~w",outcome="~w"}', [EndpointText, OutcomeText]).
label_text(Class, Text) :-
    atom(Class),
    safe_label(Class, ClassText),
    format(atom(Text), '{class="~w"}', [ClassText]).

safe_label(Value, Text) :-
    ( atom(Value) -> atom_string(Value, Raw)
    ; string(Value) -> Raw = Value
    ; term_string(Value, Raw)
    ),
    split_string(Raw, "\"\\\n", "", Parts),
    atomic_list_concat(Parts, '_', Text).
