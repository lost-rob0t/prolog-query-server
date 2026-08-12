:- module(kb_analysis,
          [ analyze_documents/4
          ]).

:- use_module(library(lists)).
:- use_module(builtins).

analyze_documents(KB, Release, Documents, Analysis) :-
    collect_documents(Documents, Definitions, References, Rules),
    dependency_edges(References, Edges),
    arity_errors(Definitions, References, ArityErrors),
    builtin_arity_errors(References, BuiltinErrors),
    recursion_analysis(Definitions, References, Recursions, NegationErrors),
    append([ArityErrors, BuiltinErrors, NegationErrors], Errors),
    undefined_warnings(Definitions, References, UndefinedWarnings),
    reachability(Definitions, Rules, Reachable, UnreachablePredicates, UnreachableRules),
    unreachable_warnings(UnreachablePredicates, UnreachableRules, ReachabilityWarnings),
    append(UndefinedWarnings, ReachabilityWarnings, Warnings),
    length(Documents, DocumentCount),
    length(Definitions, DefinitionCount),
    length(Edges, EdgeCount),
    length(Errors, ErrorCount),
    length(Warnings, WarningCount),
    (Errors == [] -> Valid = true ; Valid = false),
    maplist(signature_json, Reachable, ReachableJSON),
    maplist(signature_json, UnreachablePredicates, UnreachableJSON),
    Analysis = _{kb:KB,
                 release:Release,
                 valid:Valid,
                 counts:_{documents:DocumentCount,
                          definitions:DefinitionCount,
                          dependency_edges:EdgeCount,
                          errors:ErrorCount,
                          warnings:WarningCount},
                 dependency_graph:Edges,
                 recursion:Recursions,
                 reachable_predicates:ReachableJSON,
                 unreachable_predicates:UnreachableJSON,
                 unreachable_rules:UnreachableRules,
                 errors:Errors,
                 warnings:Warnings}.

collect_documents(Documents, Definitions, References, Rules) :-
    collect_documents(Documents, [], [], [], DefRev, RefRev, RuleRev),
    reverse(DefRev, Definitions),
    reverse(RefRev, References),
    reverse(RuleRev, Rules).

collect_documents([], Definitions, References, Rules, Definitions, References, Rules).
collect_documents([Document|Rest], D0, R0, Rules0, Definitions, References, Rules) :-
    (   document_enabled(Document)
    ->  collect_document(Document, D0, R0, Rules0, D1, R1, Rules1)
    ;   D1 = D0, R1 = R0, Rules1 = Rules0
    ),
    collect_documents(Rest, D1, R1, Rules1, Definitions, References, Rules).

collect_document(Document, D0, R0, Rules0, D, R, Rules) :-
    get_dict(type, Document, "prolog_fact"),
    !,
    document_source(Document, Source),
    fact_signature(Document, Signature),
    D = [def(Signature, Source, fact)|D0],
    R = R0,
    Rules = Rules0.
collect_document(Document, D0, R0, Rules0, D, R, Rules) :-
    get_dict(type, Document, "prolog_rule"),
    !,
    document_source(Document, Source),
    get_dict(head, Document, Head),
    goal_signature(Head, HeadSignature),
    (get_dict(body, Document, Body) -> true ; Body = []),
    collect_body(Body, HeadSignature, Source, BodyReferences),
    positive_user_dependencies(BodyReferences, PositiveDeps),
    reverse(BodyReferences, BodyRefsRev),
    append(BodyRefsRev, R0, R),
    D = [def(HeadSignature, Source, rule)|D0],
    Rules = [rule(Source, HeadSignature, PositiveDeps)|Rules0].
collect_document(_Document, D, R, Rules, D, R, Rules).

collect_body([], _Head, _Source, []).
collect_body([Item|Rest], Head, Source, [Reference|References]) :-
    body_reference(Item, Head, Source, Reference),
    collect_body(Rest, Head, Source, References).

body_reference(Item, Head, Source, ref(Head, Signature, negative, Source)) :-
    is_dict(Item), get_dict(not, Item, Goal), !, goal_signature(Goal, Signature).
body_reference(Item, Head, Source, ref(Head, Signature, positive, Source)) :-
    goal_signature(Item, Signature).

positive_user_dependencies(References, Dependencies) :-
    findall(Signature,
            ( member(ref(_, Signature, positive, _), References),
              \+ builtin_signature_name(Signature)
            ), Raw),
    sort(Raw, Dependencies).

fact_signature(Document, sig(Name, Arity)) :-
    get_dict(predicate, Document, Predicate),
    (get_dict(args, Document, Args) -> true ; Args = []),
    length(Args, Arity), normalize_name(Predicate, Name).

goal_signature(Goal, sig(Name, Arity)) :-
    get_dict(predicate, Goal, Predicate),
    (get_dict(args, Goal, Args) -> true ; Args = []),
    length(Args, Arity), normalize_name(Predicate, Name).

dependency_edges(References, Edges) :-
    findall(Edge,
            ( member(ref(From, To, Polarity, Source), References),
              \+ builtin_signature_name(To),
              signature_json(From, FromJSON), signature_json(To, ToJSON),
              atom_string(Polarity, PolarityString),
              Edge = _{from:FromJSON,to:ToJSON,polarity:PolarityString,source:Source}
            ), Edges).

arity_errors(Definitions, References, Errors) :-
    findall(use(Name, Arity, Source),
            user_signature_use(Definitions, References, Name, Arity, Source), Uses),
    findall(Name, member(use(Name, _, _), Uses), Names0), sort(Names0, Names),
    findall(Error,
            ( member(Name, Names),
              findall(A, member(use(Name, A, _), Uses), A0), sort(A0, Arities),
              Arities = [_,_|_],
              findall(S, member(use(Name, _, S), Uses), S0), sort(S0, Sources),
              Error = _{code:"arity_mismatch",predicate:Name,arities:Arities,sources:Sources}
            ), Errors).

user_signature_use(Definitions, _References, Name, Arity, Source) :-
    member(def(sig(Name, Arity), Source, _), Definitions), \+ builtin_name_string(Name).
user_signature_use(_Definitions, References, Name, Arity, Source) :-
    member(ref(_, sig(Name, Arity), _, Source), References), \+ builtin_name_string(Name).

builtin_arity_errors(References, Errors) :-
    findall(Error,
            ( member(ref(_, sig(Name, Arity), _Polarity, Source), References),
              builtin_name_string(Name), atom_string(Predicate, Name),
              builtins:builtin_signature(Predicate, Expected), Arity =\= Expected,
              Error = _{code:"builtin_arity_mismatch",predicate:Name,
                        expected:Expected,actual:Arity,source:Source}
            ), Errors).

undefined_warnings(Definitions, References, Warnings) :-
    findall(Warning,
            ( member(ref(_, Signature, positive, Source), References),
              \+ builtin_signature_name(Signature),
              \+ definition_exists(Signature, Definitions),
              signature_json(Signature, SignatureJSON),
              Warning = _{code:"undefined_predicate",predicate:SignatureJSON,source:Source}
            ), Raw),
    sort(Raw, Warnings).

recursion_analysis(Definitions, References, Recursions, NegationErrors) :-
    graph_vertices(Definitions, References, Vertices),
    user_graph_edges(References, GraphEdges),
    strongly_connected_sets(Vertices, GraphEdges, Components),
    findall(Recursion,
            ( member(Component, Components), recursive_component(Component, GraphEdges),
              maplist(signature_json, Component, Predicates),
              component_negative_edges(Component, GraphEdges, NegativeEdges),
              (NegativeEdges == [] -> NegativeCycle=false ; NegativeCycle=true),
              Recursion = _{predicates:Predicates,negative_cycle:NegativeCycle,
                            negative_edges:NegativeEdges}
            ), Recursions),
    findall(_{code:"non_stratified_negation",predicates:Predicates,
              negative_edges:NegativeEdges},
            ( member(R, Recursions), get_dict(negative_cycle,R,true),
              get_dict(predicates,R,Predicates), get_dict(negative_edges,R,NegativeEdges) ),
            NegationErrors).

graph_vertices(Definitions, References, Vertices) :-
    findall(S, member(def(S, _, _), Definitions), Defs),
    findall(S, (member(ref(_, S, _, _), References), \+ builtin_signature_name(S)), Refs),
    append(Defs, Refs, All), sort(All, Vertices).

user_graph_edges(References, Edges) :-
    findall(edge(From,To,Polarity,Source),
            (member(ref(From,To,Polarity,Source),References), \+ builtin_signature_name(To)),
            Edges).

strongly_connected_sets(Vertices, Edges, Components) :-
    findall(Component,
            ( member(Vertex, Vertices),
              findall(Other,
                      (member(Other,Vertices),mutually_reachable(Vertex,Other,Edges)), C0),
              sort(C0, Component)
            ), Raw),
    sort(Raw, Components).

mutually_reachable(Vertex, Vertex, _Edges) :- !.
mutually_reachable(A, B, Edges) :- reachable(A,B,Edges), reachable(B,A,Edges).
reachable(From, To, Edges) :- reachable(From,To,Edges,[From]).
reachable(From, To, Edges, _Visited) :- member(edge(From,To,_,_),Edges).
reachable(From, To, Edges, Visited) :-
    member(edge(From,Next,_,_),Edges), \+ memberchk(Next,Visited),
    reachable(Next,To,Edges,[Next|Visited]).

recursive_component([Only], Edges) :- member(edge(Only,Only,_,_),Edges), !.
recursive_component([_,_|_], _Edges).

component_negative_edges(Component, Edges, JSONEdges) :-
    findall(_{from:FromJSON,to:ToJSON,source:Source},
            ( member(edge(From,To,negative,Source),Edges),
              memberchk(From,Component), memberchk(To,Component),
              signature_json(From,FromJSON), signature_json(To,ToJSON) ), JSONEdges).

reachability(Definitions, Rules, Reachable, UnreachablePredicates, UnreachableRules) :-
    findall(S, member(def(S,_,fact),Definitions), FactSeeds),
    findall(H, (member(rule(_,H,D),Rules),D==[]), RuleSeeds),
    append(FactSeeds,RuleSeeds,Seeds0), sort(Seeds0,Seeds),
    reachability_fixpoint(Seeds,Rules,Reachable),
    findall(S,member(def(S,_,_),Definitions),Defined0), sort(Defined0,Defined),
    subtract(Defined,Reachable,UnreachablePredicates),
    findall(Source,
            (member(rule(Source,_Head,Dependencies),Rules),
             \+ all_reachable(Dependencies,Reachable)), UR0),
    sort(UR0,UnreachableRules).

reachability_fixpoint(Current, Rules, Reachable) :-
    findall(Head,
            (member(rule(_,Head,Dependencies),Rules),all_reachable(Dependencies,Current)), Derivable),
    append(Current,Derivable,Next0), sort(Next0,Next),
    (Next==Current -> Reachable=Current ; reachability_fixpoint(Next,Rules,Reachable)).

all_reachable([], _Reachable).
all_reachable([Dependency|Rest], Reachable) :-
    memberchk(Dependency,Reachable), all_reachable(Rest,Reachable).

unreachable_warnings([], [], []).
unreachable_warnings(Predicates, Rules, Warnings) :-
    findall(_{code:"unreachable_predicate",predicate:JSON},
            (member(Signature,Predicates),signature_json(Signature,JSON)), PW),
    findall(_{code:"unreachable_rule",source:Source},member(Source,Rules),RW),
    append(PW,RW,Warnings).

definition_exists(Signature, Definitions) :- memberchk(def(Signature,_,_),Definitions).

builtin_signature_name(sig(Name, _Arity)) :- builtin_name_string(Name).
builtin_name_string(Name) :- atom_string(Predicate,Name), builtins:builtin_name(Predicate).

signature_json(sig(Name, Arity), _{predicate:Name,arity:Arity}).
document_enabled(Document) :- (get_dict(enabled,Document,Enabled)->Enabled\==false;true).
document_source(Document, Source) :- (get_dict('_id',Document,S)->Source=S;Source="unsaved").
normalize_name(Value, Name) :- (string(Value)->Name=Value;atom(Value)->atom_string(Value,Name)).
