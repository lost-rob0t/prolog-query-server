:- module(expert_system,
          [ replace_kb/3,
            upsert_document/3,
            remove_document/2,
            run_query/4,
            validate_document/1,
            knowledge_base_loaded/1
          ]).

:- use_module(library(option)).
:- use_module(library(error)).
:- use_module(library(solution_sequences)).
:- use_module(library(time)).
:- use_module(builtins).
:- use_module(config).
:- use_module(resource_limits, []).

:- dynamic kb_clause/6.
:- dynamic kb_loaded/1.
:- dynamic kb_document_bytes/3.

replace_kb(KB, Documents, Stats) :-
    resource_limits:validate_snapshot(Documents),
    retractall(kb_clause(KB, _, _, _, _, _)),
    retractall(kb_loaded(KB)),
    retractall(kb_document_bytes(KB, _, _)),
    load_documents(Documents, KB, 0, 0, 0, Facts, Rules, Skipped),
    assertz(kb_loaded(KB)),
    Stats = _{facts:Facts, rules:Rules, skipped_disabled:Skipped}.

upsert_document(KB, Document, Outcome) :-
    required(Document, '_id', Source),
    resource_limits:validate_document(Document),
    ensure_incremental_capacity(KB, Source, Document),
    (   document_enabled(Document)
    ->  document_kind(Document, Kind),
        validate_kind(Kind, Document),
        retractall(kb_clause(KB, _, _, Source, _, _)),
        retractall(kb_document_bytes(KB, Source, _)),
        assert_document_clause(Kind, KB, Document),
        remember_document_bytes(KB, Source, Document),
        Outcome = Kind
    ;   retractall(kb_clause(KB, _, _, Source, _, _)),
        retractall(kb_document_bytes(KB, Source, _)),
        Outcome = disabled
    ).

remove_document(KB, Source) :-
    retractall(kb_clause(KB, _, _, Source, _, _)),
    retractall(kb_document_bytes(KB, Source, _)).

ensure_incremental_capacity(KB, Source, Document) :-
    loaded_usage_excluding(KB, Source, Count0, Bytes0),
    (   document_enabled(Document)
    ->  resource_limits:json_bytes(Document, DocumentBytes),
        Count is Count0 + 1,
        Bytes is Bytes0 + DocumentBytes
    ;   Count = Count0,
        Bytes = Bytes0
    ),
    config:max_kb_documents(MaxDocuments),
    (   Count =< MaxDocuments
    ->  true
    ;   resource_limits:resource_limit(kb_document_count,
                                        _{max_documents:MaxDocuments,
                                          actual_documents:Count})
    ),
    config:max_kb_bytes(MaxBytes),
    (   Bytes =< MaxBytes
    ->  true
    ;   resource_limits:resource_limit(kb_size,
                                        _{max_bytes:MaxBytes,
                                          actual_bytes:Bytes})
    ).

loaded_usage_excluding(KB, Source, Count, Bytes) :-
    findall(DocumentBytes,
            ( kb_document_bytes(KB, ExistingSource, DocumentBytes),
              ExistingSource \== Source
            ),
            ByteValues),
    length(ByteValues, Count),
    sum_list(ByteValues, Bytes).

remember_document_bytes(KB, Source, Document) :-
    resource_limits:json_bytes(Document, Bytes),
    assertz(kb_document_bytes(KB, Source, Bytes)).

run_query(KB, Query, Options, Result) :-
    (   kb_loaded(KB)
    ->  true
    ;   throw(error(existence_error(knowledge_base, KB), _))
    ),
    decode_goal(Query, Goal, [], VarsReversed),
    reverse(VarsReversed, Vars),
    query_options(Options,
                  QueryId,
                  MaxDepth,
                  MaxSolutions,
                  TimeoutMs,
                  MaxInferenceSteps,
                  MaxProofNodes,
                  MaxProofBytes,
                  Trace,
                  ExplanationMode),
    ProbeSolutions is MaxSolutions + 1,
    setup_call_cleanup(
        nb_setval(pqs_depth_hit, false),
        run_bounded_query(QueryId,
                          TimeoutMs,
                          MaxInferenceSteps,
                          ProbeSolutions,
                          KB,
                          Goal,
                          Vars,
                          MaxDepth,
                          Trace,
                          ExplanationMode,
                          MaxProofNodes,
                          MaxProofBytes,
                          Candidates,
                          DepthHit),
        nb_delete(pqs_depth_hit)),
    finalize_candidates(Candidates,
                        MaxSolutions,
                        QueryId,
                        MaxProofNodes,
                        MaxProofBytes,
                        Solutions,
                        SolutionLimitHit,
                        ProofNodes,
                        ProofBytes),
    length(Solutions, Count),
    Budget = _{timeout_ms:TimeoutMs,
               max_depth:MaxDepth,
               max_solutions:MaxSolutions,
               max_inference_steps:MaxInferenceSteps,
               max_proof_nodes:MaxProofNodes,
               max_proof_bytes:MaxProofBytes},
    Result = _{kb:KB,
               query_id:QueryId,
               count:Count,
               solutions:Solutions,
               budget:Budget,
               limit_hits:_{max_depth:DepthHit,
                            max_solutions:SolutionLimitHit},
               proof_usage:_{nodes:ProofNodes, bytes:ProofBytes}}.

query_options(Options,
              QueryId,
              MaxDepth,
              MaxSolutions,
              TimeoutMs,
              MaxInferenceSteps,
              MaxProofNodes,
              MaxProofBytes,
              Trace,
              ExplanationMode) :-
    config:max_query_depth(DefaultDepth),
    config:max_query_solutions(DefaultSolutions),
    config:query_timeout_ms(DefaultTimeoutMs),
    config:max_inference_steps(DefaultInferenceSteps),
    config:max_proof_nodes(DefaultProofNodes),
    config:max_proof_bytes(DefaultProofBytes),
    option(query_id(QueryId), Options, null),
    option(max_depth(MaxDepth), Options, DefaultDepth),
    option(max_solutions(MaxSolutions), Options, DefaultSolutions),
    option(timeout_ms(TimeoutMs), Options, DefaultTimeoutMs),
    option(max_inference_steps(MaxInferenceSteps), Options, DefaultInferenceSteps),
    option(max_proof_nodes(MaxProofNodes), Options, DefaultProofNodes),
    option(max_proof_bytes(MaxProofBytes), Options, DefaultProofBytes),
    option(trace(Trace), Options, false),
    option(explanation_mode(ExplanationMode0), Options, full),
    positive_integer(max_depth, MaxDepth),
    positive_integer(max_solutions, MaxSolutions),
    positive_integer(timeout_ms, TimeoutMs),
    positive_integer(max_inference_steps, MaxInferenceSteps),
    positive_integer(max_proof_nodes, MaxProofNodes),
    positive_integer(max_proof_bytes, MaxProofBytes),
    normalize_explanation_mode(ExplanationMode0, ExplanationMode).

run_bounded_query(QueryId,
                  TimeoutMs,
                  MaxInferenceSteps,
                  ProbeSolutions,
                  KB,
                  Goal,
                  Vars,
                  MaxDepth,
                  Trace,
                  ExplanationMode,
                  MaxProofNodes,
                  MaxProofBytes,
                  Candidates,
                  DepthHit) :-
    TimeoutSeconds is TimeoutMs / 1000.0,
    catch(call_with_time_limit(
              TimeoutSeconds,
              call_with_inference_limit(
                  findnsols(ProbeSolutions,
                            Candidate,
                            query_solution(KB,
                                           Goal,
                                           Vars,
                                           MaxDepth,
                                           Trace,
                                           ExplanationMode,
                                           MaxProofNodes,
                                           MaxProofBytes,
                                           QueryId,
                                           Candidate),
                            Candidates),
                  MaxInferenceSteps,
                  InferenceResult)),
          TimeoutError,
          handle_timeout_exception(TimeoutError, QueryId, TimeoutMs)),
    (   InferenceResult == inference_limit_exceeded
    ->  throw(error(pqs_query_resource(inference_budget,
                                       QueryId,
                                       _{max_inference_steps:MaxInferenceSteps}),
                      _))
    ;   true
    ),
    nb_getval(pqs_depth_hit, DepthHit).

handle_timeout_exception(time_limit_exceeded, QueryId, TimeoutMs) :-
    !,
    throw(error(pqs_query_resource(query_timeout,
                                   QueryId,
                                   _{timeout_ms:TimeoutMs}),
                _)).
handle_timeout_exception(error(time_limit_exceeded, _), QueryId, TimeoutMs) :-
    !,
    throw(error(pqs_query_resource(query_timeout,
                                   QueryId,
                                   _{timeout_ms:TimeoutMs}),
                _)).
handle_timeout_exception(Error, _QueryId, _TimeoutMs) :-
    throw(Error).

finalize_candidates(Candidates,
                    MaxSolutions,
                    QueryId,
                    MaxProofNodes,
                    MaxProofBytes,
                    Solutions,
                    SolutionLimitHit,
                    ProofNodes,
                    ProofBytes) :-
    length(Candidates, CandidateCount),
    (   CandidateCount > MaxSolutions
    ->  SolutionLimitHit = true
    ;   SolutionLimitHit = false
    ),
    take_candidates(MaxSolutions, Candidates, Returned),
    candidate_solutions(Returned, Solutions),
    candidate_proof_totals(Returned, 0, 0, ProofNodes, ProofBytes),
    ensure_proof_totals(QueryId,
                        MaxProofNodes,
                        MaxProofBytes,
                        ProofNodes,
                        ProofBytes).

take_candidates(0, _Candidates, []) :- !.
take_candidates(_N, [], []) :- !.
take_candidates(N, [Candidate|Rest], [Candidate|Taken]) :-
    N > 0,
    Next is N - 1,
    take_candidates(Next, Rest, Taken).

candidate_solutions([], []).
candidate_solutions([candidate(Solution, _, _)|Rest], [Solution|Solutions]) :-
    candidate_solutions(Rest, Solutions).

candidate_proof_totals([], Nodes, Bytes, Nodes, Bytes).
candidate_proof_totals([candidate(_, CandidateNodes, CandidateBytes)|Rest],
                       Nodes0,
                       Bytes0,
                       Nodes,
                       Bytes) :-
    Nodes1 is Nodes0 + CandidateNodes,
    Bytes1 is Bytes0 + CandidateBytes,
    candidate_proof_totals(Rest, Nodes1, Bytes1, Nodes, Bytes).

ensure_proof_totals(QueryId, MaxProofNodes, _MaxProofBytes, Nodes, _Bytes) :-
    Nodes > MaxProofNodes,
    !,
    throw(error(pqs_query_resource(proof_limit,
                                   QueryId,
                                   _{max_proof_nodes:MaxProofNodes,
                                     actual_proof_nodes:Nodes}),
                _)).
ensure_proof_totals(QueryId, _MaxProofNodes, MaxProofBytes, _Nodes, Bytes) :-
    Bytes > MaxProofBytes,
    !,
    throw(error(pqs_query_resource(proof_limit,
                                   QueryId,
                                   _{max_proof_bytes:MaxProofBytes,
                                     actual_proof_bytes:Bytes}),
                _)).
ensure_proof_totals(_QueryId, _MaxProofNodes, _MaxProofBytes, _Nodes, _Bytes).

knowledge_base_loaded(KB) :-
    kb_loaded(KB).

positive_integer(_Name, Value) :-
    integer(Value),
    Value > 0,
    !.
positive_integer(Name, Value) :-
    throw(error(domain_error(positive_integer(Name), Value), _)).

normalize_explanation_mode(full, full) :- !.
normalize_explanation_mode(compact, compact) :- !.
normalize_explanation_mode("full", full) :- !.
normalize_explanation_mode("compact", compact) :- !.
normalize_explanation_mode(Value, _) :-
    throw(error(domain_error(explanation_mode, Value), _)).

validate_document(Document) :-
    resource_limits:validate_document(Document),
    document_kind(Document, Kind),
    validate_kind(Kind, Document).

validate_kind(fact, Document) :-
    fact_clause(Document, _Head, _Body, _Source, _Revision).
validate_kind(rule, Document) :-
    rule_clause(Document, _Head, _Body, _Source, _Revision).

load_documents([], _KB, Facts, Rules, Skipped, Facts, Rules, Skipped).
load_documents([Document|Rest], KB, Facts0, Rules0, Skipped0, Facts, Rules, Skipped) :-
    (   document_enabled(Document)
    ->  document_kind(Document, Kind),
        load_document(Kind, KB, Document, Facts0, Rules0, Facts1, Rules1),
        Skipped1 = Skipped0
    ;   Facts1 = Facts0,
        Rules1 = Rules0,
        Skipped1 is Skipped0 + 1
    ),
    load_documents(Rest, KB, Facts1, Rules1, Skipped1, Facts, Rules, Skipped).

load_document(fact, KB, Document, Facts0, Rules, Facts, Rules) :-
    fact_clause(Document, Head, Body, Source, Revision),
    assertz(kb_clause(KB, Head, Body, Source, Revision, fact)),
    remember_document_bytes(KB, Source, Document),
    Facts is Facts0 + 1.
load_document(rule, KB, Document, Facts, Rules0, Facts, Rules) :-
    rule_clause(Document, Head, Body, Source, Revision),
    assertz(kb_clause(KB, Head, Body, Source, Revision, rule)),
    remember_document_bytes(KB, Source, Document),
    Rules is Rules0 + 1.

assert_document_clause(fact, KB, Document) :-
    fact_clause(Document, Head, Body, Source, Revision),
    assertz(kb_clause(KB, Head, Body, Source, Revision, fact)).
assert_document_clause(rule, KB, Document) :-
    rule_clause(Document, Head, Body, Source, Revision),
    assertz(kb_clause(KB, Head, Body, Source, Revision, rule)).

fact_clause(Document, Head, [], Source, Revision) :-
    require_type(Document, "prolog_fact"),
    required(Document, predicate, Predicate),
    optional(Document, args, [], Args),
    GoalDict = _{predicate:Predicate, args:Args},
    decode_goal(GoalDict, Head, [], Vars),
    ensure_user_head(Head),
    (   Vars == [],
        ground(Head)
    ->  true
    ;   throw(error(domain_error(ground_fact, Document), _))
    ),
    document_source(Document, Source, Revision).

rule_clause(Document, Head, Body, Source, Revision) :-
    require_type(Document, "prolog_rule"),
    required(Document, head, HeadDict),
    optional(Document, body, [], BodyDicts),
    must_be(list, BodyDicts),
    decode_goal(HeadDict, Head, [], Vars0),
    ensure_user_head(Head),
    decode_body(BodyDicts, Body, Vars0, _Vars),
    document_source(Document, Source, Revision).

decode_body([], [], Vars, Vars).
decode_body([Item|Rest], [Goal|Goals], Vars0, Vars) :-
    decode_body_item(Item, Goal, Vars0, Vars1),
    decode_body(Rest, Goals, Vars1, Vars).

decode_body_item(Item, not(Goal), Vars0, Vars) :-
    is_dict(Item),
    get_dict(not, Item, Negated),
    !,
    decode_goal(Negated, Goal, Vars0, Vars).
decode_body_item(Item, Goal, Vars0, Vars) :-
    decode_goal(Item, Goal, Vars0, Vars).

decode_goal(Dict, goal(Predicate, Args), Vars0, Vars) :-
    must_be(dict, Dict),
    required(Dict, predicate, PredicateValue),
    as_atom(PredicateValue, Predicate),
    valid_predicate(Predicate),
    optional(Dict, args, [], Nodes),
    must_be(list, Nodes),
    decode_nodes(Nodes, Args, Vars0, Vars).

decode_nodes([], [], Vars, Vars).
decode_nodes([Node|Rest], [Value|Values], Vars0, Vars) :-
    decode_node(Node, Value, Vars0, Vars1),
    decode_nodes(Rest, Values, Vars1, Vars).

decode_node(Node, Value, Vars0, Vars) :-
    (   is_dict(Node), get_dict(var, Node, Name0)
    ->  variable_name(Name0, Name),
        intern_variable(Name, Value, Vars0, Vars)
    ;   is_dict(Node), get_dict(atom, Node, Atom0)
    ->  as_atom(Atom0, Value),
        Vars = Vars0
    ;   is_dict(Node), get_dict(functor, Node, Functor0)
    ->  as_atom(Functor0, Functor),
        valid_predicate(Functor),
        optional(Node, args, [], ArgNodes),
        must_be(list, ArgNodes),
        decode_nodes(ArgNodes, CompoundArgs, Vars0, Vars),
        Value =.. [Functor|CompoundArgs]
    ;   is_dict(Node)
    ->  throw(error(domain_error(term_ast, Node), _))
    ;   Value = Node,
        Vars = Vars0
    ).

intern_variable(Name, Variable, Vars, Vars) :-
    memberchk(Name-Existing, Vars),
    !,
    Variable = Existing.
intern_variable(Name, Variable, Vars0, [Name-Variable|Vars0]).

ensure_user_head(goal(Predicate, _Args)) :-
    (   builtins:builtin_name(Predicate)
    ->  throw(error(permission_error(define, builtin_predicate, Predicate), _))
    ;   true
    ).

query_solution(KB,
               Goal,
               Vars,
               MaxDepth,
               TraceEnabled,
               ExplanationMode,
               MaxProofNodes,
               MaxProofBytes,
               QueryId,
               candidate(Solution, ProofNodes, ProofBytes)) :-
    solve_goal(KB,
               Goal,
               0,
               MaxDepth,
               TraceEnabled,
               MaxProofNodes,
               QueryId,
               0,
               ProofNodes,
               Sources,
               FullProof),
    bindings_dict(Vars, Bindings),
    (   TraceEnabled == true
    ->  format_proof(ExplanationMode, FullProof, Proof),
        resource_limits:json_bytes(Proof, ProofBytes),
        ensure_single_proof(QueryId,
                            MaxProofNodes,
                            MaxProofBytes,
                            ProofNodes,
                            ProofBytes),
        Solution = _{bindings:Bindings, sources:Sources, proof:Proof}
    ;   ProofBytes = 0,
        Solution = _{bindings:Bindings}
    ).

ensure_single_proof(QueryId, MaxProofNodes, _MaxProofBytes, Nodes, _Bytes) :-
    Nodes > MaxProofNodes,
    !,
    throw(error(pqs_query_resource(proof_limit,
                                   QueryId,
                                   _{max_proof_nodes:MaxProofNodes,
                                     actual_proof_nodes:Nodes}),
                _)).
ensure_single_proof(QueryId, _MaxProofNodes, MaxProofBytes, _Nodes, Bytes) :-
    Bytes > MaxProofBytes,
    !,
    throw(error(pqs_query_resource(proof_limit,
                                   QueryId,
                                   _{max_proof_bytes:MaxProofBytes,
                                     actual_proof_bytes:Bytes}),
                _)).
ensure_single_proof(_QueryId, _MaxProofNodes, _MaxProofBytes, _Nodes, _Bytes).

solve_goal(_KB,
           Goal,
           _Depth,
           _MaxDepth,
           TraceEnabled,
           MaxProofNodes,
           QueryId,
           Nodes0,
           Nodes,
           [],
           Proof) :-
    builtins:builtin_goal(Goal),
    !,
    builtins:execute_builtin(Goal),
    Goal = goal(Predicate, _Args),
    proof_node(TraceEnabled, MaxProofNodes, QueryId, Nodes0, Nodes),
    (   TraceEnabled == true
    ->  builtin_proof(Predicate, Goal, Proof)
    ;   Proof = none
    ).
solve_goal(KB,
           Goal,
           Depth,
           MaxDepth,
           TraceEnabled,
           MaxProofNodes,
           QueryId,
           Nodes0,
           Nodes,
           [Source|Sources],
           Proof) :-
    kb_clause(KB, Head0, Body0, Source, Revision, Kind),
    copy_term((Head0, Body0), (Head, Body)),
    Goal = Head,
    (   Depth < MaxDepth
    ->  NextDepth is Depth + 1,
        solve_body(KB,
                   Body,
                   NextDepth,
                   MaxDepth,
                   TraceEnabled,
                   MaxProofNodes,
                   QueryId,
                   Nodes0,
                   BodyNodes,
                   Sources,
                   Children),
        proof_node(TraceEnabled, MaxProofNodes, QueryId, BodyNodes, Nodes),
        make_user_proof(TraceEnabled,
                        Goal,
                        Source,
                        Revision,
                        Kind,
                        Children,
                        Proof)
    ;   mark_depth_hit,
        fail
    ).

solve_body(_KB,
           [],
           _Depth,
           _MaxDepth,
           _TraceEnabled,
           _MaxProofNodes,
           _QueryId,
           Nodes,
           Nodes,
           [],
           []).
solve_body(KB,
           [not(Goal)|Rest],
           Depth,
           MaxDepth,
           TraceEnabled,
           MaxProofNodes,
           QueryId,
           Nodes0,
           Nodes,
           Sources,
           [NegationProof|Proofs]) :-
    !,
    \+ solve_goal(KB,
                  Goal,
                  Depth,
                  MaxDepth,
                  false,
                  MaxProofNodes,
                  QueryId,
                  Nodes0,
                  _IgnoredNodes,
                  _NegatedSources,
                  _NegatedProof),
    proof_node(TraceEnabled, MaxProofNodes, QueryId, Nodes0, Nodes1),
    make_negation_proof(TraceEnabled, Goal, NegationProof),
    solve_body(KB,
               Rest,
               Depth,
               MaxDepth,
               TraceEnabled,
               MaxProofNodes,
               QueryId,
               Nodes1,
               Nodes,
               Sources,
               Proofs).
solve_body(KB,
           [Goal|Rest],
           Depth,
           MaxDepth,
           TraceEnabled,
           MaxProofNodes,
           QueryId,
           Nodes0,
           Nodes,
           Sources,
           [HeadProof|TailProofs]) :-
    solve_goal(KB,
               Goal,
               Depth,
               MaxDepth,
               TraceEnabled,
               MaxProofNodes,
               QueryId,
               Nodes0,
               Nodes1,
               HeadSources,
               HeadProof),
    solve_body(KB,
               Rest,
               Depth,
               MaxDepth,
               TraceEnabled,
               MaxProofNodes,
               QueryId,
               Nodes1,
               Nodes,
               TailSources,
               TailProofs),
    append(HeadSources, TailSources, Sources).

proof_node(false, _MaxProofNodes, _QueryId, Nodes, Nodes) :- !.
proof_node(true, MaxProofNodes, QueryId, Nodes0, Nodes) :-
    Nodes is Nodes0 + 1,
    (   Nodes =< MaxProofNodes
    ->  true
    ;   throw(error(pqs_query_resource(proof_limit,
                                       QueryId,
                                       _{max_proof_nodes:MaxProofNodes,
                                         actual_proof_nodes:Nodes}),
                      _))
    ).

mark_depth_hit :-
    nb_setval(pqs_depth_hit, true).

make_user_proof(false, _Goal, _Source, _Revision, _Kind, _Children, none) :- !.
make_user_proof(true, Goal, Source, Revision, Kind, Children, Proof) :-
    goal_json(Goal, GoalJSON),
    source_json(Source, Revision, SourceJSON),
    kind_json(Kind, KindJSON),
    Proof = _{kind:KindJSON,
              goal:GoalJSON,
              source:SourceJSON,
              children:Children}.

make_negation_proof(false, _Goal, none) :- !.
make_negation_proof(true, Goal, Proof) :-
    goal_json(Goal, GoalJSON),
    Proof = _{kind:"negation",
              goal:GoalJSON,
              decision:"not_provable",
              children:[]}.

builtin_proof(Predicate, Goal, Proof) :-
    goal_json(Goal, GoalJSON),
    atom_string(Predicate, PredicateString),
    Proof = _{kind:"builtin",
              predicate:PredicateString,
              goal:GoalJSON,
              decision:"succeeded",
              children:[]}.

format_proof(full, Proof, Proof).
format_proof(compact, Full, Compact) :-
    compact_proof(Full, Compact).

compact_proof(Full, Compact) :-
    get_dict(kind, Full, Kind),
    proof_predicate(Full, Predicate),
    get_dict(children, Full, Children0),
    maplist(compact_proof, Children0, Children),
    Base = _{kind:Kind,
             predicate:Predicate,
             children:Children},
    compact_source(Full, Base, WithSource),
    compact_decision(Full, WithSource, Compact).

proof_predicate(Proof, Predicate) :-
    (   get_dict(predicate, Proof, Predicate0)
    ->  Predicate = Predicate0
    ;   get_dict(goal, Proof, Goal),
        get_dict(predicate, Goal, Predicate)
    ).

compact_source(Full, Base, Compact) :-
    (   get_dict(source, Full, Source),
        is_dict(Source),
        get_dict(id, Source, Id)
    ->  put_dict(source, Base, Id, Compact)
    ;   Compact = Base
    ).

compact_decision(Full, Base, Compact) :-
    (   get_dict(decision, Full, Decision)
    ->  put_dict(decision, Base, Decision, Compact)
    ;   Compact = Base
    ).

goal_json(goal(Predicate, Args), _{predicate:PredicateString, args:EncodedArgs}) :-
    atom_string(Predicate, PredicateString),
    maplist(encode_value, Args, EncodedArgs).

source_json(Source, Revision, _{id:Source, rev:Revision}).

kind_json(fact, "fact").
kind_json(rule, "rule").

bindings_dict(Vars, Dict) :-
    maplist(binding_pair, Vars, Pairs),
    dict_create(Dict, bindings, Pairs).

binding_pair(Name-Value, Key-Encoded) :-
    atom_string(Key, Name),
    encode_value(Value, Encoded).

encode_value(Value, _{unbound:true}) :-
    var(Value),
    !.
encode_value(Value, Encoded) :-
    atomic(Value),
    !,
    atom_json_value(Value, Encoded).
encode_value(Value, _{functor:FunctorString, args:EncodedArgs}) :-
    compound(Value),
    Value =.. [Functor|Args],
    atom_string(Functor, FunctorString),
    maplist(encode_value, Args, EncodedArgs).

atom_json_value(Value, String) :-
    atom(Value),
    Value \== true,
    Value \== false,
    Value \== null,
    !,
    atom_string(Value, String).
atom_json_value(Value, Value).

document_kind(Document, fact) :-
    require_type(Document, "prolog_fact"),
    !.
document_kind(Document, rule) :-
    require_type(Document, "prolog_rule"),
    !.
document_kind(Document, _) :-
    throw(error(domain_error(prolog_document_type, Document), _)).

document_enabled(Document) :-
    optional(Document, enabled, true, Enabled),
    Enabled \== false.

document_source(Document, Source, Revision) :-
    (   get_dict('_id', Document, Source0)
    ->  Source = Source0
    ;   Source = "unsaved"
    ),
    (   get_dict('_rev', Document, Revision0)
    ->  Revision = Revision0
    ;   Revision = null
    ).

require_type(Document, Expected) :-
    required(Document, type, Actual),
    (   text_equal(Actual, Expected)
    ->  true
    ;   fail
    ).

required(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(error(existence_error(key, Key), _))
    ).

optional(Dict, Key, Default, Value) :-
    (   get_dict(Key, Dict, Value0)
    ->  Value = Value0
    ;   Value = Default
    ).

as_atom(Value, Atom) :-
    (   atom(Value)
    ->  Atom = Value
    ;   string(Value)
    ->  atom_string(Atom, Value)
    ;   throw(error(type_error(text, Value), _))
    ).

variable_name(Value, Name) :-
    (   string(Value)
    ->  Name = Value
    ;   atom(Value)
    ->  atom_string(Value, Name)
    ;   throw(error(type_error(variable_name, Value), _))
    ),
    string_length(Name, Length),
    Length > 0.

valid_predicate(Predicate) :-
    atom_codes(Predicate, Codes),
    Codes = [First|Rest],
    predicate_start(First),
    maplist(predicate_continue, Rest),
    !.
valid_predicate(Predicate) :-
    throw(error(domain_error(predicate_name, Predicate), _)).

predicate_start(Code) :-
    code_type(Code, lower),
    !.
predicate_start(0'_).

predicate_continue(Code) :-
    code_type(Code, alnum),
    !.
predicate_continue(0'_).

text_equal(Left, Right) :-
    as_atom(Left, LeftAtom),
    as_atom(Right, RightAtom),
    LeftAtom == RightAtom.
