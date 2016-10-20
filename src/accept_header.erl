%% @doc HTTP instrumentation helpers
-module(accept_header).

-export([parse/1,
         negotiate/2]).

-include("accept.hrl").

%%====================================================================
%% Public API
%%====================================================================

%% @doc
%% Parses Accept header, returns a list of media_ranges.
%%
%% <pre lang="erlang-repl">
%% 1> accept_header:parse("text/*;q=0.3, text/html;q=0.7, text/html;level=1,"
%%                        "text/html;level=2;q=0.4, */*;q=0.5").
%% [{media_range,"text","*",0.3,[]},
%%  {media_range,"text","html",0.7,[]},
%%  {media_range,"text","html",1,[{"level","1"}]},
%%  {media_range,"text","html",0.4,[{"level","2"}]},
%%  {media_range,"*","*",0.5,[]}]
%% </pre>
%% @end
-spec parse(AcceptString) -> Result when
    AcceptString :: binary() | string (),
    Result :: [#media_range{}].
parse(AcceptString) ->
  lists:map(fun parse_media_range/1,
            string:tokens(ensure_string(AcceptString), ",")).

%% @doc
%% Negotiates the most appropriate content_type given the accept header
%% and a list of alternatives.
%%
%% <pre lang="erlang-repl">
%% 2> accept_header:negotiate("text/*;q=0.3, text/html;q=0.7, text/html;level=1,"
%%                            "text/html;level=2;q=0.4, */*;q=0.5",
%%                            ["text/html;level=2", "text/html;level-3"]).
%% "text/html;level-3"
%% </pre>
%% @end
-spec negotiate(Header, Alternatives) -> Match when
    Header :: BinaryOrString,
    Alternatives :: [Alternative],
    Alternative :: BinaryOrString | {BinaryOrString | Tag},
    BinaryOrString :: binary() | string(),
    Tag :: any(),
    Match :: Tag | nomatch.
negotiate(Header, Alternatives) ->

  MediaRanges = parse(Header),

  Alts = lists:map(fun (Alt) ->
                       {A, Tag} = case Alt of
                                    {_, _} -> Alt;
                                    _ -> {Alt, Alt}
                                  end,
                       PA = parse_media_range(ensure_string(A)),
                       %% list of Alt-MR scores
                       AltMRScores = lists:map(fun (MR) ->
                                                   {score_alt(MR, PA), MR}
                                               end,
                                               MediaRanges),
                       %% best Media Range match for this Alternative
                       [{Score, BMR} | _ ] = lists:sort(fun scored_cmp/2,
                                                        AltMRScores),
                       case Score of
                         0 ->
                           {-1, Tag};
                         _ ->
                           #media_range{q = BMRQ} = BMR,
                           {BMRQ, Tag}
                       end
                   end,
                   Alternatives),

  %% find alternative with the best score
  %% keysort is stable so order of Alternatives preserved
  %% after sorting Tail has the best score.
  %% However if multiple alternatives have the same score as Tail
  %% we should find first best alternative to respect user's priority.
  {_, Tag} = find_preferred_best(lists:keysort(1, Alts)),
  Tag.

%%====================================================================
%% Private Parts
%%====================================================================

parse_media_range(RawMRString) ->
  [MR | RawParams] = string:tokens(RawMRString, ";"),

  [Type, Subtype] = lists:map(fun string:strip/1, string:tokens(MR, "/")),

  Params = lists:filtermap(fun parse_media_range_param/1, RawParams),

  {Q, ParamsWOQ} = find_media_range_q(Params),

  #media_range{type = Type,
               subtype = Subtype,
               q = Q,
               params = ParamsWOQ}.

parse_media_range_param(Param) ->
  case string:tokens(Param, "=") of
    [Name, Value] -> {true, {Name, Value}};
    _ -> false %% simply ignore malformed Name=Value pairs
  end.

find_media_range_q(Params) ->
  {parse_q(proplists:get_value("q", Params, "1")),
   proplists:delete("q", Params)}.

parse_q(Q) ->
  try
    case lists:member($., Q) of
      true ->
        list_to_float(Q);
      false ->
        list_to_integer(Q)
    end
  catch error:badarg ->
      0
  end.

scored_cmp({S1, _}, {S2, _}) ->
  S1 > S2.

find_preferred_best(Sorted) ->
  [B | R] = lists:reverse(Sorted),
  find_preferred_best(B, R).

find_preferred_best({Q, _}, [{Q, _} = H | R]) ->
  find_preferred_best(H, R);
find_preferred_best(B, []) ->
  B;
find_preferred_best(B, _) ->
  B.


%% Alternative "text/plain; version=4"
%% text/plain; version=4 > text/plan > text/plain; n=v > text/* > */* > image/*
score_alt(#media_range{type = Type,
                       subtype = SubType,
                       params = MRParams},
          #media_range{type = Type,
                       subtype = SubType,
                       params = AltParams}) ->
  8 + 4 + score_params(MRParams, AltParams);
score_alt(#media_range{type = Type,
                       subtype = "*"},
          #media_range{type = Type}) ->
  8 + 3;
score_alt(#media_range{type = "*"},
          _) ->
  8;
score_alt(_, _) ->
  0.

%% If media range doesn't have params 1
%% If params match 2
%% otherwise 0
score_params([], _) ->
  1;
score_params(MRParams, AltParams) when length(MRParams) == length(AltParams) ->
  case lists:sort(MRParams) == lists:sort(AltParams) of
    true -> 2;
    _ -> 0
  end;
score_params(_, _) ->
  0.

ensure_string(V) when is_list(V) ->
  V;
ensure_string(V) when is_binary(V) ->
  binary_to_list(V).