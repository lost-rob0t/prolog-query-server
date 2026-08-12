:- begin_tests(proof_trees).

:- use_module('../src/expert_system').

proof_fact(Id, Rev, Predicate, Args, Doc) :-
    Doc = _{'_id':Id,
            '_rev':Rev,
            type:"prolog_fact",
            kb:"proof",
            enabled:true,
            predicate:Predicate,
            args:Args}.

proof_rule(Id, Rev, Head, Body, Doc) :-
    Doc = _{'_id':Id,
            '_rev':Rev,
            type:"prolog_rule",
            kb:"proof",
            enabled:true,
            head:Head,
            body:Body}.

test(full_proof_contains_nested_sources_builtins_and_negation) :-
    proof_fact("fact:alice", "1-fact", "person", ["alice"], Person),
    proof_rule("rule:eligible",
               "2-rule",
               _{predicate:"eligible", args:[_{var:"X"}]},
               [ _{predicate:"person", args:[_{var:"X"}]},
                 _{predicate:"neq", args:[_{var:"X"}, "bob"]},
                 _{not:_{predicate:"blocked", args:[_{var:"X"}]}}
               ],
               Rule),
    replace_kb("proof", [Person, Rule], _),
    run_query("proof",
              _{predicate:"eligible", args:[_{var:"Who"}]},
              [trace(true), explanation_mode(full)],
              Result),
    get_dict(solutions, Result, [Solution]),
    get_dict(bindings, Solution, Bindings),
    get_dict('Who', Bindings, "alice"),
    get_dict(sources, Solution, ["rule:eligible", "fact:alice"]),
    get_dict(proof, Solution, Proof),
    get_dict(kind, Proof, "rule"),
    get_dict(goal, Proof, TopGoal),
    get_dict(predicate, TopGoal, "eligible"),
    get_dict(source, Proof, RuleSource),
    get_dict(id, RuleSource, "rule:eligible"),
    get_dict(rev, RuleSource, "2-rule"),
    get_dict(children, Proof, [FactProof, BuiltinProof, NegationProof]),
    get_dict(kind, FactProof, "fact"),
    get_dict(source, FactProof, FactSource),
    get_dict(id, FactSource, "fact:alice"),
    get_dict(rev, FactSource, "1-fact"),
    get_dict(kind, BuiltinProof, "builtin"),
    get_dict(predicate, BuiltinProof, "neq"),
    get_dict(decision, BuiltinProof, "succeeded"),
    get_dict(kind, NegationProof, "negation"),
    get_dict(decision, NegationProof, "not_provable"),
    get_dict(goal, NegationProof, NegatedGoal),
    get_dict(predicate, NegatedGoal, "blocked").

test(compact_proof_preserves_structure_without_revision_payload) :-
    proof_fact("fact:alice", "1-fact", "person", ["alice"], Person),
    proof_rule("rule:member",
               "3-rule",
               _{predicate:"member", args:[_{var:"X"}]},
               [_{predicate:"person", args:[_{var:"X"}]}],
               Rule),
    replace_kb("proof-compact", [Person, Rule], _),
    run_query("proof-compact",
              _{predicate:"member", args:[_{var:"Who"}]},
              [trace(true), explanation_mode(compact)],
              Result),
    get_dict(solutions, Result, [Solution]),
    get_dict(proof, Solution, Proof),
    get_dict(kind, Proof, "rule"),
    get_dict(predicate, Proof, "member"),
    get_dict(source, Proof, "rule:member"),
    \+ get_dict(goal, Proof, _),
    get_dict(children, Proof, [Child]),
    get_dict(kind, Child, "fact"),
    get_dict(predicate, Child, "person"),
    get_dict(source, Child, "fact:alice").

test(alternate_proofs_retain_distinct_source_documents) :-
    proof_fact("fact:a", "1-a", "person", ["a"], A),
    proof_fact("fact:b", "1-b", "person", ["b"], B),
    replace_kb("proof-alt", [A, B], _),
    run_query("proof-alt",
              _{predicate:"person", args:[_{var:"Who"}]},
              [trace(true), explanation_mode(full)],
              Result),
    get_dict(solutions, Result, [SA, SB]),
    get_dict(proof, SA, PA),
    get_dict(proof, SB, PB),
    get_dict(source, PA, SourceA),
    get_dict(source, PB, SourceB),
    get_dict(id, SourceA, "fact:a"),
    get_dict(id, SourceB, "fact:b").

test(invalid_explanation_mode_rejected,
     [throws(error(domain_error(explanation_mode, "verbose"), _))]) :-
    replace_kb("proof-invalid", [], _),
    run_query("proof-invalid",
              _{predicate:"anything", args:[]},
              [trace(true), explanation_mode("verbose")],
              _).

:- end_tests(proof_trees).
