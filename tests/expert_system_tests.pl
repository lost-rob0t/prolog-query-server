:- begin_tests(expert_system).

:- use_module('../src/expert_system').

fact(Id, Predicate, Args, Doc) :-
    Doc = _{'_id':Id,
            type:"prolog_fact",
            kb:"demo",
            enabled:true,
            predicate:Predicate,
            args:Args}.

rule(Id, Head, Body, Doc) :-
    Doc = _{'_id':Id,
            type:"prolog_rule",
            kb:"demo",
            enabled:true,
            head:Head,
            body:Body}.

test(forward_chain_across_persisted_documents) :-
    fact("fact:human:socrates", "human", ["socrates"], Human),
    rule("rule:mortal",
         _{predicate:"mortal", args:[_{var:"X"}]},
         [_{predicate:"human", args:[_{var:"X"}]}],
         Mortal),
    rule("rule:needs-coffee",
         _{predicate:"needs_coffee", args:[_{var:"X"}]},
         [_{predicate:"mortal", args:[_{var:"X"}]}],
         Coffee),
    replace_kb("demo", [Human, Mortal, Coffee], Stats),
    get_dict(facts, Stats, 1),
    get_dict(rules, Stats, 2),
    run_query("demo",
              _{predicate:"needs_coffee", args:[_{var:"Who"}]},
              [max_depth(16), max_solutions(10), trace(true)],
              Result),
    get_dict(count, Result, 1),
    get_dict(solutions, Result, [Solution]),
    get_dict(bindings, Solution, Bindings),
    get_dict('Who', Bindings, "socrates"),
    get_dict(sources, Solution,
             ["rule:needs-coffee", "rule:mortal", "fact:human:socrates"]).

test(disabled_documents_are_not_loaded) :-
    Disabled = _{'_id':"fact:hidden",
                 type:"prolog_fact",
                 kb:"demo",
                 enabled:false,
                 predicate:"secret",
                 args:["x"]},
    replace_kb("demo", [Disabled], Stats),
    get_dict(skipped_disabled, Stats, 1),
    run_query("demo",
              _{predicate:"secret", args:[_{var:"X"}]},
              [max_depth(8), max_solutions(10)],
              Result),
    get_dict(count, Result, 0).

test(shared_rule_variables) :-
    fact("fact:parent:alice:bob", "parent", ["alice", "bob"], Parent1),
    fact("fact:parent:bob:carol", "parent", ["bob", "carol"], Parent2),
    rule("rule:grandparent",
         _{predicate:"grandparent", args:[_{var:"X"}, _{var:"Z"}]},
         [ _{predicate:"parent", args:[_{var:"X"}, _{var:"Y"}]},
           _{predicate:"parent", args:[_{var:"Y"}, _{var:"Z"}]}
         ],
         Grandparent),
    replace_kb("demo", [Parent1, Parent2, Grandparent], _),
    run_query("demo",
              _{predicate:"grandparent", args:["alice", _{var:"Who"}]},
              [max_depth(16), max_solutions(10)],
              Result),
    get_dict(solutions, Result, [Solution]),
    get_dict(bindings, Solution, Bindings),
    get_dict('Who', Bindings, "carol").

test(negation_as_failure) :-
    fact("fact:person:alice", "person", ["alice"], Person),
    fact("fact:blocked:bob", "blocked", ["bob"], Blocked),
    rule("rule:allowed",
         _{predicate:"allowed", args:[_{var:"X"}]},
         [ _{predicate:"person", args:[_{var:"X"}]},
           _{not:_{predicate:"blocked", args:[_{var:"X"}]}}
         ],
         Allowed),
    replace_kb("demo", [Person, Blocked, Allowed], _),
    run_query("demo",
              _{predicate:"allowed", args:[_{var:"Who"}]},
              [max_depth(16), max_solutions(10)],
              Result),
    get_dict(solutions, Result, [Solution]),
    get_dict(bindings, Solution, Bindings),
    get_dict('Who', Bindings, "alice").

test(eq_and_neq_builtins_in_rules) :-
    fact("fact:person:alice", "person", ["alice"], Alice),
    fact("fact:person:bob", "person", ["bob"], Bob),
    rule("rule:not-bob",
         _{predicate:"not_bob", args:[_{var:"X"}]},
         [ _{predicate:"person", args:[_{var:"X"}]},
           _{predicate:"neq", args:[_{var:"X"}, "bob"]}
         ],
         NotBob),
    rule("rule:alice-only",
         _{predicate:"alice_only", args:[_{var:"X"}]},
         [ _{predicate:"not_bob", args:[_{var:"X"}]},
           _{predicate:"eq", args:[_{var:"X"}, "alice"]}
         ],
         AliceOnly),
    replace_kb("demo", [Alice, Bob, NotBob, AliceOnly], _),
    run_query("demo",
              _{predicate:"alice_only", args:[_{var:"Who"}]},
              [max_depth(16), max_solutions(10)],
              Result),
    get_dict(solutions, Result, [Solution]),
    get_dict(bindings, Solution, Bindings),
    get_dict('Who', Bindings, "alice").

test(max_solutions_is_enforced) :-
    fact("f1", "person", ["a"], A),
    fact("f2", "person", ["b"], B),
    fact("f3", "person", ["c"], C),
    replace_kb("demo", [A, B, C], _),
    run_query("demo",
              _{predicate:"person", args:[_{var:"Who"}]},
              [max_depth(8), max_solutions(2)],
              Result),
    get_dict(count, Result, 2).

test(max_depth_stops_recursive_proof) :-
    fact("human", "human", ["socrates"], Human),
    rule("mortal",
         _{predicate:"mortal", args:[_{var:"X"}]},
         [_{predicate:"human", args:[_{var:"X"}]}],
         Mortal),
    replace_kb("demo", [Human, Mortal], _),
    run_query("demo",
              _{predicate:"mortal", args:["socrates"]},
              [max_depth(1), max_solutions(10)],
              Result),
    get_dict(count, Result, 0).

test(replacing_snapshot_removes_old_knowledge) :-
    fact("old", "old_fact", ["x"], Old),
    fact("new", "new_fact", ["y"], New),
    replace_kb("demo", [Old], _),
    replace_kb("demo", [New], _),
    run_query("demo", _{predicate:"old_fact", args:["x"]}, [], OldResult),
    run_query("demo", _{predicate:"new_fact", args:["y"]}, [], NewResult),
    get_dict(count, OldResult, 0),
    get_dict(count, NewResult, 1).

test(knowledge_bases_are_isolated) :-
    fact("a", "marker", ["alpha"], Alpha),
    fact("b", "marker", ["beta"], Beta),
    replace_kb("kb-a", [Alpha], _),
    replace_kb("kb-b", [Beta], _),
    run_query("kb-a", _{predicate:"marker", args:[_{var:"X"}]}, [], AResult),
    run_query("kb-b", _{predicate:"marker", args:[_{var:"X"}]}, [], BResult),
    get_dict(solutions, AResult, [ASolution]),
    get_dict(solutions, BResult, [BSolution]),
    get_dict(bindings, ASolution, ABinds),
    get_dict(bindings, BSolution, BBinds),
    get_dict('X', ABinds, "alpha"),
    get_dict('X', BBinds, "beta").

test(compound_terms_round_trip_to_json_ast) :-
    fact("point", "located", [_{functor:"point", args:[10, 20]}], Point),
    replace_kb("demo", [Point], _),
    run_query("demo",
              _{predicate:"located", args:[_{var:"Where"}]},
              [],
              Result),
    get_dict(solutions, Result, [Solution]),
    get_dict(bindings, Solution, Bindings),
    get_dict('Where', Bindings, Encoded),
    get_dict(functor, Encoded, "point"),
    get_dict(args, Encoded, [10, 20]).

test(trace_is_absent_when_disabled) :-
    fact("f", "person", ["alice"], Fact),
    replace_kb("demo", [Fact], _),
    run_query("demo",
              _{predicate:"person", args:[_{var:"Who"}]},
              [trace(false)],
              Result),
    get_dict(solutions, Result, [Solution]),
    \+ get_dict(sources, Solution, _).

test(knowledge_base_loaded_after_replace) :-
    replace_kb("loaded-kb", [], _),
    knowledge_base_loaded("loaded-kb").

test(query_unloaded_kb_rejected,
     [throws(error(existence_error(knowledge_base, "never-loaded"), _))]) :-
    run_query("never-loaded", _{predicate:"x", args:[]}, [], _).

test(reject_non_ground_fact,
     [throws(error(domain_error(ground_fact, _), _))]) :-
    Bad = _{type:"prolog_fact",
            kb:"demo",
            predicate:"human",
            args:[_{var:"X"}]},
    validate_document(Bad).

test(reject_arbitrary_term_dict,
     [throws(error(domain_error(term_ast, _), _))]) :-
    Bad = _{type:"prolog_fact",
            predicate:"payload",
            args:[_{call:"shell"}]},
    validate_document(Bad).

test(reject_invalid_predicate_name,
     [throws(error(domain_error(predicate_name, 'Shell'), _))]) :-
    Bad = _{type:"prolog_fact", predicate:"Shell", args:[]},
    validate_document(Bad).

test(reject_zero_depth,
     [throws(error(domain_error(positive_integer(max_depth), 0), _))]) :-
    replace_kb("demo", [], _),
    run_query("demo", _{predicate:"anything", args:[]}, [max_depth(0)], _).

test(predicate_named_shell_is_only_data) :-
    fact("safe-shell-data", "shell", ["id"], Fact),
    replace_kb("demo", [Fact], _),
    run_query("demo", _{predicate:"shell", args:["id"]}, [], Result),
    get_dict(count, Result, 1).

:- end_tests(expert_system).
