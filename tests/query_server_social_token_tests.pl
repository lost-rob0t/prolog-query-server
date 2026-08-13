:- begin_tests(query_server_social_tokens).

:- use_module('../src/query_server_protocol').

test(direct_social_content_counts_each_occurrence,
     [setup(reset_state)]) :-
    handle_command(["add_fun",
                    "where(eq(field(\"dtype\"),\"SocialMPost\"),for_each(tokens(lower(normalize_text(field(\"content\")))),emit(item,1)))."],
                   true),
    handle_command(["map_doc",
                    _{dtype:"SocialMPost", content:"Trump trump TRUMP"}],
                   Result),
    assertion(Result == [[["trump", 1], ["trump", 1], ["trump", 1]]]).

test(punctuation_normalization_preserves_occurrences,
     [setup(reset_state)]) :-
    handle_command(["add_fun",
                    "for_each(tokens(lower(normalize_text(field(\"content\")))),emit(item,1))."],
                   true),
    handle_command(["map_doc", _{content:"Oil, oil! GAS...gas?"}], Result),
    assertion(Result == [[["oil", 1], ["oil", 1], ["gas", 1], ["gas", 1]]]).

test(mastodon_html_is_normalized_to_visible_text,
     [setup(reset_state)]) :-
    handle_command(["add_fun",
                    "for_each(tokens(lower(normalize_text(field(\"content\")))),emit(item,1))."],
                   true),
    handle_command(["map_doc",
                    _{content:"<p>Trump &amp; oil</p><p>tariff</p>"}],
                   Result),
    assertion(Result == [[["trump",1], ["oil",1], ["tariff",1]]]).

test(unrelated_document_can_be_filtered,
     [setup(reset_state)]) :-
    handle_command(["add_fun",
                    "where(eq(field(\"dtype\"),\"SocialMPost\"),for_each(tokens(lower(normalize_text(field(\"content\")))),emit(item,1)))."],
                   true),
    handle_command(["map_doc", _{dtype:"Person", content:"trump"}], Result),
    assertion(Result == [[]]).

test(iterates_object_collection_with_item_paths,
     [setup(reset_state)]) :-
    handle_command(["add_fun",
                    "for_each(field(\"pairs\"),emit(item(\"word\"),item(\"count\")))."],
                   true),
    handle_command(["map_doc",
                    _{pairs:[_{word:"oil", count:2}, _{word:"gas", count:3}]}],
                   Result),
    assertion(Result == [[["oil",2], ["gas",3]]]).

test(time_parts_are_utc_and_composable_in_keys,
     [setup(reset_state)]) :-
    handle_command(["add_fun",
                    "for_each(tokens(lower(field(\"content\"))),emit(array([item,time_part(\"year\",field(\"date_updated\")),time_part(\"month\",field(\"date_updated\")),time_part(\"day\",field(\"date_updated\")),time_part(\"hour\",field(\"date_updated\"))]),1))."],
                   true),
    handle_command(["map_doc", _{content:"Trump", date_updated:0}], Result),
    assertion(Result == [[[ ["trump",1970,1,1,0], 1 ]]]).

test(rejects_item_outside_iterator,
     [ setup(reset_state),
       throws(error(permission_error(use, iterator_item_outside_for_each, item), _))
     ]) :-
    handle_command(["add_fun", "emit(item,1)."], _).

test(rejects_item_path_outside_iterator,
     [ setup(reset_state),
       throws(error(permission_error(use, iterator_item_outside_for_each, item(_)), _))
     ]) :-
    handle_command(["add_fun", "emit(item(\"word\"),1)."], _).

test(rejects_unknown_time_unit,
     [ setup(reset_state),
       throws(error(domain_error(time_part_unit, _), _))
     ]) :-
    handle_command(["add_fun", "emit(time_part(\"minute\",field(\"date_updated\")),1)."], _).

test(enforces_iterator_depth,
     [ setup(reset_state),
       throws(error(resource_error(max_iterator_depth), _))
     ]) :-
    handle_command(["add_fun",
                    "for_each(field(\"a\"),for_each(field(\"b\"),for_each(field(\"c\"),for_each(field(\"d\"),for_each(field(\"e\"),emit(item,1))))))."],
                   _).

test(enforces_collection_limit,
     [ setup(reset_state),
       throws(error(resource_error(max_collection_items), _))
     ]) :-
    length(Items, 4097),
    maplist(=("x"), Items),
    handle_command(["add_fun", "for_each(field(\"items\"),emit(item,1))."], true),
    handle_command(["map_doc", _{items:Items}], _).

test(enforces_text_limit,
     [ setup(reset_state),
       throws(error(resource_error(max_text_codepoints), _))
     ]) :-
    length(Codes, 65537),
    maplist(=(0'a), Codes),
    string_codes(Text, Codes),
    handle_command(["add_fun", "emit(lower(field(\"content\")),1)."], true),
    handle_command(["map_doc", _{content:Text}], _).

test(sum_reducer_still_accepts_token_rows,
     [setup(reset_state)]) :-
    Rows = [ [["trump", "a"], 1], [["trump", "b"], 1], [["trump", "c"], 1] ],
    handle_command(["reduce", ["sum."], Rows], Reply),
    assertion(Reply == [true, [3]]).

:- end_tests(query_server_social_tokens).
