:- begin_tests(changes_streaming).

:- use_module('../src/config', []).
:- use_module('../src/expert_system').
:- use_module('../src/kb_service', []).

with_env(Name, Value, Goal) :-
    (   getenv(Name, Old)
    ->  Restore = setenv(Name, Old)
    ;   Restore = unsetenv(Name)
    ),
    setup_call_cleanup(setenv(Name, Value),
                       call(Goal),
                       call(Restore)).

fact(KB, Id, Value, Doc) :-
    Doc = _{'_id':Id,
            type:"prolog_fact",
            kb:KB,
            release:"legacy",
            enabled:true,
            predicate:"item",
            args:[Value]}.

change(Id, Doc, _{id:Id, doc:Doc}).

query_count(RuntimeKB, Value, Count) :-
    expert_system:run_query(RuntimeKB,
                            _{predicate:"item", args:[Value]},
                            [query_id("changes-streaming-unit")],
                            Result),
    get_dict(count, Result, Count).

test(configurable_batch_size) :-
    with_env('PQS_CHANGES_BATCH_SIZE', '2',
             ( config:changes_batch_size(Size),
               assertion(Size =:= 2)
             )).

test(successful_batch_applies_and_advances_sequence) :-
    KB = "stream-unit-success",
    RuntimeKB = kb_release(KB, "legacy"),
    fact(KB, "base", "base", Base),
    fact(KB, "next", "next", Next),
    expert_system:replace_kb(RuntimeKB, [Base], _),
    kb_service:set_kb_sequence(RuntimeKB, 10),
    change("next", Next, Change),
    kb_service:apply_changes_batch([Change],
                                   RuntimeKB,
                                   KB,
                                   "legacy",
                                   11,
                                   Applied,
                                   Removed,
                                   Ignored),
    assertion(Applied =:= 1),
    assertion(Removed =:= 0),
    assertion(Ignored =:= 0),
    assertion(kb_service:kb_sequence(RuntimeKB, 11)),
    query_count(RuntimeKB, "next", Count),
    assertion(Count =:= 1).

test(conflicted_late_change_rolls_back_entire_batch) :-
    KB = "stream-unit-conflict",
    RuntimeKB = kb_release(KB, "legacy"),
    fact(KB, "base", "base", Base),
    fact(KB, "first", "first", First),
    fact(KB, "conflict", "conflict", Conflict0),
    put_dict(_{'_conflicts':["2-loser"]}, Conflict0, Conflict),
    expert_system:replace_kb(RuntimeKB, [Base], _),
    kb_service:set_kb_sequence(RuntimeKB, 20),
    change("first", First, FirstChange),
    change("conflict", Conflict, ConflictChange),
    catch(kb_service:apply_changes_batch([FirstChange, ConflictChange],
                                         RuntimeKB,
                                         KB,
                                         "legacy",
                                         21,
                                         _Applied,
                                         _Removed,
                                         _Ignored),
          error(permission_error(load, conflicted_knowledge_document, _), _),
          true),
    assertion(kb_service:kb_sequence(RuntimeKB, 20)),
    query_count(RuntimeKB, "first", FirstCount),
    query_count(RuntimeKB, "base", BaseCount),
    assertion(FirstCount =:= 0),
    assertion(BaseCount =:= 1).

test(kb_limit_failure_rolls_back_entire_batch) :-
    KB = "stream-unit-limit",
    RuntimeKB = kb_release(KB, "legacy"),
    fact(KB, "base", "base", Base),
    fact(KB, "first", "first", First),
    fact(KB, "second", "second", Second),
    expert_system:replace_kb(RuntimeKB, [Base], _),
    kb_service:set_kb_sequence(RuntimeKB, 30),
    change("first", First, FirstChange),
    change("second", Second, SecondChange),
    catch(with_env('PQS_MAX_KB_DOCUMENTS', '2',
                   kb_service:apply_changes_batch([FirstChange, SecondChange],
                                                  RuntimeKB,
                                                  KB,
                                                  "legacy",
                                                  31,
                                                  _Applied,
                                                  _Removed,
                                                  _Ignored)),
          error(pqs_resource_limit(kb_document_count, _), _),
          true),
    assertion(kb_service:kb_sequence(RuntimeKB, 30)),
    query_count(RuntimeKB, "first", FirstCount),
    query_count(RuntimeKB, "base", BaseCount),
    assertion(FirstCount =:= 0),
    assertion(BaseCount =:= 1).

:- end_tests(changes_streaming).
