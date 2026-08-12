:- begin_tests(query_server_protocol).

:- use_module('../src/query_server_protocol').

test(map_doc_executes_safe_prolog_dsl,
     [setup(reset_state)]) :-
    handle_command(["add_fun",
                    "where(gt(field(\"score\"), 50), emit(field(\"name\"), field(\"score\")))."],
                   true),
    handle_command(["map_doc", _{name:"alice", score:60}], Result),
    assertion(Result == [[["alice", 60]]]).

test(map_doc_can_emit_objects,
     [setup(reset_state)]) :-
    handle_command(["add_fun",
                    "emit(field(\"type\"), object([\"id\"-field(\"_id\"), \"kind\"-field(\"type\")]))."],
                   true),
    handle_command(["map_doc", _{'_id':"a1", type:"person"}], Result),
    assertion(Result == [[["person", json{id:"a1", kind:"person"}]]]).

test(nested_fields_and_arrays,
     [setup(reset_state)]) :-
    handle_command(["add_fun",
                    "emit(field([\"profile\",\"name\"]), array([field(\"score\"), 7]))."],
                   true),
    handle_command(["map_doc", _{profile:_{name:"alice"}, score:99}], Result),
    assertion(Result == [[["alice", [99, 7]]]]).

test(all_emits_multiple_rows,
     [setup(reset_state)]) :-
    handle_command(["add_fun",
                    "all([emit(field(\"a\"),1),emit(field(\"b\"),2)])."],
                   true),
    handle_command(["map_doc", _{a:"x", b:"y"}], Result),
    assertion(Result == [[["x", 1], ["y", 2]]]).

test(multiple_map_functions_are_isolated,
     [setup(reset_state)]) :-
    handle_command(["add_fun", "emit(field(\"a\"),1)."], true),
    handle_command(["add_fun", "emit(field(\"b\"),2)."], true),
    handle_command(["map_doc", _{a:"x", b:"y"}], Result),
    assertion(Result == [[ ["x", 1] ], [ ["y", 2] ]]).

test(boolean_conditions,
     [setup(reset_state)]) :-
    handle_command(["add_fun",
                    "where(and([exists(field(\"name\")),gte(field(\"score\"),10),not(eq(field(\"name\"),\"blocked\"))]),emit(field(\"name\"),true))."],
                   true),
    handle_command(["map_doc", _{name:"alice", score:10}], Yes),
    handle_command(["map_doc", _{name:"blocked", score:10}], No),
    assertion(Yes == [[["alice", true]]]),
    assertion(No == [[]]).

test(or_condition,
     [setup(reset_state)]) :-
    handle_command(["add_fun",
                    "where(or([lt(field(\"n\"),0),gt(field(\"n\"),10)]),emit(field(\"n\"),true))."],
                   true),
    handle_command(["map_doc", _{n:11}], Result),
    assertion(Result == [[[11, true]]]).

test(reset_removes_registered_maps,
     [setup(reset_state)]) :-
    handle_command(["add_fun", "emit(field(\"a\"),1)."], true),
    handle_command(["reset"], true),
    handle_command(["map_doc", _{a:"x"}], Result),
    assertion(Result == []).

test(reduce_sum_count_min_max,
     [setup(reset_state)]) :-
    Rows = [ [["a", "1-a"], 10],
             [["b", "1-b"], 20],
             [["c", "1-c"], 3]
           ],
    handle_command(["reduce", ["sum.", "count.", "min.", "max."], Rows], Reply),
    assertion(Reply == [true, [33, 3, 3, 20]]).

test(couchdb_35_reduce_context_argument,
     [setup(reset_state)]) :-
    Rows = [ [["a", "1-a"], 10], [["b", "1-b"], 20] ],
    handle_command(["reduce", ["count."], Rows, "view-context"], Reply),
    assertion(Reply == [true, [2]]).

test(reduce_stats,
     [setup(reset_state)]) :-
    Rows = [ [["a", "1-a"], 2],
             [["b", "1-b"], 3]
           ],
    handle_command(["reduce", ["stats."], Rows], [true, [Stats]]),
    get_dict(sum, Stats, 5),
    get_dict(count, Stats, 2),
    get_dict(min, Stats, 2),
    get_dict(max, Stats, 3),
    get_dict(sumsqr, Stats, 13).

test(rereduce_count_sums_partial_counts,
     [setup(reset_state)]) :-
    handle_command(["rereduce", ["count."], [10, 20, 3]], Reply),
    assertion(Reply == [true, [33]]).

test(couchdb_35_rereduce_context_argument,
     [setup(reset_state)]) :-
    handle_command(["rereduce", ["count."], [10, 20, 3], "view-context"], Reply),
    assertion(Reply == [true, [33]]).

test(rereduce_stats_combines_partials,
     [setup(reset_state)]) :-
    A = _{sum:5, count:2, min:2, max:3, sumsqr:13},
    B = _{sum:10, count:1, min:10, max:10, sumsqr:100},
    handle_command(["rereduce", ["stats."], [A, B]], [true, [Stats]]),
    get_dict(sum, Stats, 15),
    get_dict(count, Stats, 3),
    get_dict(min, Stats, 2),
    get_dict(max, Stats, 10),
    get_dict(sumsqr, Stats, 113).

test(rejects_arbitrary_callable,
     [ setup(reset_state),
       throws(error(domain_error(map_dsl_action, _), _))
     ]) :-
    handle_command(["add_fun", "shell(\"id\")."], _).

test(rejects_call_wrapper,
     [ setup(reset_state),
       throws(error(domain_error(map_dsl_action, _), _))
     ]) :-
    handle_command(["add_fun", "call(shell(\"id\"))."], _).

test(rejects_non_ground_map,
     [ setup(reset_state),
       throws(error(domain_error(ground_map_dsl, _), _))
     ]) :-
    handle_command(["add_fun", "emit(X, 1)."], _).

test(rejects_unknown_reducer,
     [ setup(reset_state),
       throws(error(domain_error(reduce_dsl, shell), _))
     ]) :-
    handle_command(["reduce", ["shell."], []], _).

test(design_doc_registration_and_unsupported_execution,
     [ setup(reset_state),
       throws(error(permission_error(execute, unsupported_ddoc_function, _), _))
     ]) :-
    handle_command(["ddoc", "new", "_design/test", _{language:"prolog"}], true),
    handle_command(["ddoc", "_design/test", ["shows", "x"], []], _).

test(unknown_design_doc_rejected,
     [ setup(reset_state),
       throws(error(existence_error(design_document, "_design/missing"), _))
     ]) :-
    handle_command(["ddoc", "_design/missing", ["shows", "x"], []], _).

test(unknown_command_rejected,
     [ setup(reset_state),
       throws(error(domain_error(query_server_command, "explode"), _))
     ]) :-
    handle_command(["explode"], _).

:- end_tests(query_server_protocol).
