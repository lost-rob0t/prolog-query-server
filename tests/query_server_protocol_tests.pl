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

test(reduce_sum,
     [setup(reset_state)]) :-
    Rows = [ [["a", "1-a"], 10],
             [["b", "1-b"], 20],
             [["c", "1-c"], 3]
           ],
    handle_command(["reduce", ["sum."], Rows], Reply),
    assertion(Reply == [true, [33]]).

test(rereduce_count_sums_partial_counts,
     [setup(reset_state)]) :-
    handle_command(["rereduce", ["count."], [10, 20, 3]], Reply),
    assertion(Reply == [true, [33]]).

test(rejects_arbitrary_callable,
     [ setup(reset_state),
       throws(error(domain_error(map_dsl_action, _), _))
     ]) :-
    handle_command(["add_fun", "shell(\"id\")."], _).

:- end_tests(query_server_protocol).
