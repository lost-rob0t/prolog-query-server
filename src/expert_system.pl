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

:- dynamic kb_clause/6.
:- dynamic kb_loaded/1.

replace_kb(KB, Documents, Stats) :-
    retractall(kb_clause(KB, _, _, _, _, _)),
    retractall(kb_loaded(KB)),
    load_documents(Documents, KB, 0, 0, 0, Facts, Rules, Skipped),
    assertz(kb_loaded(KB)),
    Stats = _{facts:Facts, rules:Rules, skipped_disabled:Skipped}.

upsert_document(KB, Document, Outcome) :-
    required(Document, '_id', Source),
    (   document_enabled(Document)
    ->  document_kind(Document, Kind),
        validate_kind(Kind, Document),
        retractall(kb_clause(KB, _, _, Source, _, _)),
        assert_document_clause(Kind, KB, Document),
        Outcome = Kind
    ;   retractall(kb_clause(KB, _, _, Source, _, _)),
        Outcome = disabled
    ).

remove_document(KB, Source) :-
    retractall(kb_clause(KB, _, _, Source, _, _)).

run_query(KB, Query, Options, Result) :-
    (   kb_loaded(KB)
    ->  true
    ;   throw(error(existence_error(knowledge_base, KB), _))
    ),
    decode_goal(Query, Goal, [], VarsReversed),
    reverse(VarsReversed, Vars),
    option(max_depth(MaxDepth), Options, 32),
    option(max_solutions(MaxSolutions), Options, 100),
    option(trace(Trace), Options, false),
    option(explanation_mode(ExplanationMode0), Options, full),
    positive_integer(max_depth, MaxDepth),
    positive_integer(max_solutions, MaxSolutions),
    normalize_explanation_mode(ExplanationMode0, ExplanationMode),
    findnsols(MaxSolutions,
              Solution,
              query_solution(KB,
                             Goal,
                             Vars,
                             MaxDepth,
                             Trace,
                             ExplanationMode,
                             Solution),
              Solutions),
    length(Solutions, Count),
    Result = _{kb:KB, count:Count, solutions:Solutions}.

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
    Facts is Facts0 + 1.
load_document(rule, KB, Document, Facts, Rules0, Facts, Rules) :-
    rule_clause(Document, Head, Body, Source, Revision),
    assertz(kb_clause(KB, Head, Body, Source, Revision, rule)),
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

query_solution(KB, Goal, Vars, MaxDepth, TraceEnabled, ExplanationMode, Solution) :-
    solve_goal(KB, Goal, 0, MaxDepth, Sources, FullProof),
    bindings_dict(Vars, Bindings),
    (   TraceEnabled == true
    ->  format_proof(ExplanationMode, FullProof, Proof),
        Solution = _{bindings:Bindings, sources:Sources, proof:Proof}
    ;   Solution = _{bindings:Bindings}
    ).

solve_goal(_KB, Goal, _Depth, _MaxDepth, [], Proof) :-
    Goal = goal(eq, [Left, Right]),
    !,
    Left = Right,
    builtin_proof(eq, Goal, Proof).
solve_goal(_KB, Goal, _Depth, _MaxDepth, [], Proof) :-
    Goal = goal(neq, [Left, Right]),
    !,
    dif(Left, Right),
    builtin_proof(neq, Goal, Proof).
solve_goal(KB, Goal, Depth, MaxDepth, [Source|Sources], Proof) :-
    Depth < MaxDepth,
    kb_clause(KB, Head0, Body0, Source, Revision, Kind),
    copy_term((Head0, Body0), (Head, Body)),
    Goal = Head,
    NextDepth is Depth + 1,
    solve_body(KB, Body, NextDepth, MaxDepth, Sources, Children),
    goal_json(Goal, GoalJSON),
    source_json(Source, Revision, SourceJSON),
    kind_json(Kind, KindJSON),
    Proof = _{kind:KindJSON,
              goal:GoalJSON,
              source:SourceJSON,
              children:Children}.

solve_body(_KB, [], _Depth, _MaxDepth, [], []).
solve_body(KB,
           [not(Goal)|Rest],
           Depth,
           MaxDepth,
           Sources,
           [NegationProof|Proofs]) :-
    !,
    \+ solve_goal(KB, Goal, Depth, MaxDepth, _NegatedSources, _NegatedProof),
    goal_json(Goal, GoalJSON),
    NegationProof = _{kind:"negation",
                      goal:GoalJSON,
                      decision:"not_provable",
                      children:[]},
    solve_body(KB, Rest, Depth, MaxDepth, Sources, Proofs).
solve_body(KB,
           [Goal|Rest],
           Depth,
           MaxDepth,
           Sources,
           [HeadProof|TailProofs]) :-
    solve_goal(KB, Goal, Depth, MaxDepth, HeadSources, HeadProof),
    solve_body(KB, Rest, Depth, MaxDepth, TailSources, TailProofs),
    append(HeadSources, TailSources, Sources).

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
