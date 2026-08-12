:- begin_tests(resource_limits).

:- use_module('../src/expert_system').
:- use_module('../src/resource_limits', [effective_query_budget/2]).
:- use_module('../src/query_jobs').

fact(Id, Predicate, Args, Doc) :-
    Doc = _{'_id':Id,
            type:"prolog_fact",
            kb:"resource-tests",
            enabled:true,
            predicate:Predicate,
            args:Args}.

rule(Id, Head, Body, Doc) :-
    Doc = _{'_id':Id,
            type:"prolog_rule",
            kb:"resource-tests",
            enabled:true,
            head:Head,
            body:Body}.

with_env(Name, Value, Goal) :-
    (   getenv(Name, Old)
    ->  Restore = setenv(Name, Old)
    ;   Restore = unsetenv(Name)
    ),
    setup_call_cleanup(setenv(Name, Value),
                       call(Goal),
                       call(Restore)).

test(budget_object_precedes_legacy_top_level) :-
    effective_query_budget(_{ max_depth:12,
                              max_solutions:9,
                              budget:_{max_depth:5,
                                       max_solutions:3,
                                       timeout_ms:250}
                            },
                           Budget),
    get_dict(max_depth, Budget, 5),
    get_dict(max_solutions, Budget, 3),
    get_dict(timeout_ms, Budget, 250).

test(server_cap_clamps_requested_budget) :-
    with_env('PQS_MAX_QUERY_DEPTH', '7',
             ( effective_query_budget(_{budget:_{max_depth:700}}, Budget),
               get_dict(max_depth, Budget, 7)
             )).

test(normal_query_completes_under_budget) :-
    fact("normal", "human", ["socrates"], Human),
    replace_kb("resource-normal", [Human], _),
    run_query("resource-normal",
              _{predicate:"human", args:[_{var:"Who"}]},
              [ query_id("unit-normal"),
                timeout_ms(1000),
                max_depth(8),
                max_solutions(10),
                max_inference_steps(10000)
              ],
              Result),
    get_dict(count, Result, 1),
    get_dict(query_id, Result, "unit-normal").

test(direct_recursion_is_pruned_by_depth) :-
    rule("loop",
         _{predicate:"loop", args:[_{var:"X"}]},
         [_{predicate:"loop", args:[_{var:"X"}]}],
         Loop),
    replace_kb("resource-direct-loop", [Loop], _),
    run_query("resource-direct-loop",
              _{predicate:"loop", args:["x"]},
              [ query_id("unit-depth"),
                max_depth(4),
                max_solutions(2),
                timeout_ms(1000),
                max_inference_steps(100000)
              ],
              Result),
    get_dict(count, Result, 0),
    get_dict(limit_hits, Result, Hits),
    get_dict(max_depth, Hits, true).

test(mutual_recursion_is_pruned_by_depth) :-
    rule("a-to-b",
         _{predicate:"a", args:[_{var:"X"}]},
         [_{predicate:"b", args:[_{var:"X"}]}],
         A),
    rule("b-to-a",
         _{predicate:"b", args:[_{var:"X"}]},
         [_{predicate:"a", args:[_{var:"X"}]}],
         B),
    replace_kb("resource-mutual-loop", [A, B], _),
    run_query("resource-mutual-loop",
              _{predicate:"a", args:["x"]},
              [ query_id("unit-mutual-depth"),
                max_depth(5),
                max_solutions(2),
                timeout_ms(1000),
                max_inference_steps(100000)
              ],
              Result),
    get_dict(count, Result, 0),
    get_dict(limit_hits, Result, Hits),
    get_dict(max_depth, Hits, true).

test(inference_budget_stops_runaway_recursion,
     [throws(error(pqs_query_resource(inference_budget,
                                      "unit-inference",
                                      _), _))]) :-
    rule("budget-loop",
         _{predicate:"budget_loop", args:[_{var:"X"}]},
         [_{predicate:"budget_loop", args:[_{var:"X"}]}],
         Loop),
    replace_kb("resource-inference-loop", [Loop], _),
    run_query("resource-inference-loop",
              _{predicate:"budget_loop", args:["x"]},
              [ query_id("unit-inference"),
                max_depth(100000),
                max_solutions(1),
                timeout_ms(5000),
                max_inference_steps(100)
              ],
              _).

test(timeout_stops_runaway_recursion,
     [throws(error(pqs_query_resource(query_timeout,
                                      "unit-timeout",
                                      _), _))]) :-
    rule("timeout-loop",
         _{predicate:"timeout_loop", args:[_{var:"X"}]},
         [_{predicate:"timeout_loop", args:[_{var:"X"}]}],
         Loop),
    replace_kb("resource-timeout-loop", [Loop], _),
    run_query("resource-timeout-loop",
              _{predicate:"timeout_loop", args:["x"]},
              [ query_id("unit-timeout"),
                max_depth(1000000),
                max_solutions(1),
                timeout_ms(1),
                max_inference_steps(100000000)
              ],
              _).

test(max_solutions_has_exact_hit_metadata) :-
    fact("s1", "item", ["a"], A),
    fact("s2", "item", ["b"], B),
    fact("s3", "item", ["c"], C),
    replace_kb("resource-solutions", [A, B, C], _),
    run_query("resource-solutions",
              _{predicate:"item", args:[_{var:"X"}]},
              [query_id("unit-solutions"), max_solutions(2)],
              Result),
    get_dict(count, Result, 2),
    get_dict(limit_hits, Result, Hits),
    get_dict(max_solutions, Hits, true).

test(proof_node_limit_is_hard,
     [throws(error(pqs_query_resource(proof_limit,
                                      "unit-proof",
                                      _), _))]) :-
    fact("proof-fact", "base", ["x"], Base),
    rule("proof-rule",
         _{predicate:"derived", args:[_{var:"X"}]},
         [_{predicate:"base", args:[_{var:"X"}]}],
         Derived),
    replace_kb("resource-proof", [Base, Derived], _),
    run_query("resource-proof",
              _{predicate:"derived", args:["x"]},
              [ query_id("unit-proof"),
                trace(true),
                max_proof_nodes(1),
                max_proof_bytes(10000)
              ],
              _).

test(oversized_document_is_rejected,
     [throws(error(pqs_resource_limit(document_size, _), _))]) :-
    string_codes(Big, [120,120,120,120,120,120,120,120,120,120,
                       120,120,120,120,120,120,120,120,120,120,
                       120,120,120,120,120,120,120,120,120,120,
                       120,120,120,120,120,120,120,120,120,120,
                       120,120,120,120,120,120,120,120,120,120]),
    fact("big-doc", "payload", [Big], Doc),
    with_env('PQS_MAX_DOCUMENT_BYTES', '32',
             validate_document(Doc)).

test(rule_goal_count_is_rejected,
     [throws(error(pqs_resource_limit(rule_goal_count, _), _))]) :-
    rule("long-rule",
         _{predicate:"long", args:[]},
         [ _{predicate:"a", args:[]},
           _{predicate:"b", args:[]}
         ],
         Doc),
    with_env('PQS_MAX_RULE_GOALS', '1',
             validate_document(Doc)).

test(snapshot_document_count_is_rejected_without_replacing_old_runtime) :-
    fact("keep", "keep", ["ok"], Keep),
    replace_kb("resource-snapshot-count", [Keep], _),
    fact("a", "next", ["a"], A),
    fact("b", "next", ["b"], B),
    catch(with_env('PQS_MAX_KB_DOCUMENTS', '1',
                   replace_kb("resource-snapshot-count", [A, B], _)),
          error(pqs_resource_limit(kb_document_count, _), _),
          true),
    run_query("resource-snapshot-count",
              _{predicate:"keep", args:["ok"]},
              [],
              Result),
    get_dict(count, Result, 1).

test(snapshot_byte_limit_is_rejected,
     [throws(error(pqs_resource_limit(kb_size, _), _))]) :-
    fact("byte-limit", "payload", ["abcdefghijklmnopqrstuvwxyz"], Doc),
    with_env('PQS_MAX_KB_BYTES', '1',
             replace_kb("resource-snapshot-bytes", [Doc], _)).

test(incremental_document_count_cannot_bypass_loaded_limit,
     [throws(error(pqs_resource_limit(kb_document_count, _), _))]) :-
    fact("first", "item", ["a"], First),
    fact("second", "item", ["b"], Second),
    with_env('PQS_MAX_KB_DOCUMENTS', '1',
             ( replace_kb("resource-incremental", [First], _),
               upsert_document("resource-incremental", Second, _)
             )).

test(unknown_cancellation_is_deterministic,
     [throws(error(pqs_query_not_found("missing-query"), _))]) :-
    reset_jobs,
    cancel_query("missing-query", _).

:- end_tests(resource_limits).
