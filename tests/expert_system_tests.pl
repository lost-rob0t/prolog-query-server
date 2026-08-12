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
    get_dict(sources, Solution, ["rule:needs-coffee", "rule:mortal", "fact:human:socrates"]).

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

test(reject_non_ground_fact,
     [throws(error(domain_error(ground_fact, _), _))]) :-
    Bad = _{type:"prolog_fact",
            kb:"demo",
            predicate:"human",
            args:[_{var:"X"}]},
    validate_document(Bad).

:- end_tests(expert_system).
