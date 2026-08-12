:- begin_tests(kb_analysis).

:- use_module('../src/kb_analysis').

fact(Id, Predicate, Args, Doc) :-
    Doc = _{'_id':Id,type:"prolog_fact",kb:"analysis",release:"r",enabled:true,
            predicate:Predicate,args:Args}.
rule(Id, Predicate, Args, Body, Doc) :-
    Doc = _{'_id':Id,type:"prolog_rule",kb:"analysis",release:"r",enabled:true,
            head:_{predicate:Predicate,args:Args},body:Body}.

codes(List, Codes) :- findall(Code,(member(X,List),get_dict(code,X,Code)),Codes).

test(clean_dependency_graph_is_valid) :-
    fact("f:person","person",["alice"],Fact),
    rule("r:mortal","mortal",[_{var:"X"}],
         [_{predicate:"person",args:[_{var:"X"}]}],Rule),
    analyze_documents("analysis","r",[Fact,Rule],Analysis),
    get_dict(valid,Analysis,true),
    get_dict(errors,Analysis,[]),
    get_dict(dependency_graph,Analysis,[Edge]),
    get_dict(from,Edge,_{predicate:"mortal",arity:1}),
    get_dict(to,Edge,_{predicate:"person",arity:1}),
    get_dict(polarity,Edge,"positive"),
    get_dict(unreachable_predicates,Analysis,[]).

test(undefined_predicate_is_warning_not_error) :-
    rule("r:missing","answer",[],[_{predicate:"missing",args:[]}],Rule),
    analyze_documents("analysis","r",[Rule],Analysis),
    get_dict(valid,Analysis,true),
    get_dict(warnings,Analysis,Warnings),
    codes(Warnings,Codes),
    member("undefined_predicate",Codes),
    member("unreachable_rule",Codes).

test(user_arity_mismatch_is_error) :-
    fact("f:p1","person",["alice"],Fact),
    rule("r:p2","answer",[],[_{predicate:"person",args:["alice","extra"]}],Rule),
    analyze_documents("analysis","r",[Fact,Rule],Analysis),
    get_dict(valid,Analysis,false),
    get_dict(errors,Analysis,Errors),
    member(Error,Errors),
    get_dict(code,Error,"arity_mismatch"),
    get_dict(predicate,Error,"person"),
    get_dict(arities,Error,[1,2]).

test(builtin_arity_mismatch_is_error_without_undefined_warning) :-
    rule("r:bad-builtin","answer",[],[_{predicate:"gte",args:[1]}],Rule),
    analyze_documents("analysis","r",[Rule],Analysis),
    get_dict(valid,Analysis,false),
    get_dict(errors,Analysis,Errors),
    member(Error,Errors), get_dict(code,Error,"builtin_arity_mismatch"),
    get_dict(warnings,Analysis,Warnings),
    \+ (member(W,Warnings),get_dict(code,W,"undefined_predicate")).

test(positive_recursion_is_reported_but_valid) :-
    fact("f:edge","edge",["a","b"],Edge),
    rule("r:path-base","path",[_{var:"X"},_{var:"Y"}],
         [_{predicate:"edge",args:[_{var:"X"},_{var:"Y"}]}],Base),
    rule("r:path-rec","path",[_{var:"X"},_{var:"Y"}],
         [ _{predicate:"edge",args:[_{var:"X"},_{var:"Z"}]},
           _{predicate:"path",args:[_{var:"Z"},_{var:"Y"}]}
         ],Rec),
    analyze_documents("analysis","r",[Edge,Base,Rec],Analysis),
    get_dict(valid,Analysis,true),
    get_dict(recursion,Analysis,[Recursion]),
    get_dict(negative_cycle,Recursion,false),
    get_dict(predicates,Recursion,[_{predicate:"path",arity:2}]),
    get_dict(unreachable_predicates,Analysis,[]).

test(negative_cycle_is_invalid) :-
    rule("r:a","a",[],[_{not:_{predicate:"b",args:[]}}],A),
    rule("r:b","b",[],[_{not:_{predicate:"a",args:[]}}],B),
    analyze_documents("analysis","r",[A,B],Analysis),
    get_dict(valid,Analysis,false),
    get_dict(errors,Analysis,Errors),
    member(Error,Errors), get_dict(code,Error,"non_stratified_negation"),
    get_dict(recursion,Analysis,[Recursion]),
    get_dict(negative_cycle,Recursion,true).

test(rule_without_body_is_seed_and_reachable) :-
    Doc = _{'_id':"r:constant",type:"prolog_rule",kb:"analysis",release:"r",enabled:true,
            head:_{predicate:"constant",args:["yes"]}},
    analyze_documents("analysis","r",[Doc],Analysis),
    get_dict(valid,Analysis,true),
    get_dict(reachable_predicates,Analysis,[_{predicate:"constant",arity:1}]).

:- end_tests(kb_analysis).
