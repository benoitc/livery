%% @doc Handler behaviour for Livery HTTP server.
%%
%% Implement this behaviour to handle HTTP requests.
%%
%% Example:
%% ```
%% -module(my_handler).
%% -behaviour(livery_handler).
%% -export([init/2, handle/2, terminate/2]).
%%
%% init(Req, Opts) ->
%%     {ok, Req, #{opts => Opts}}.
%%
%% handle(Req, State) ->
%%     {reply, 200, [{<<"content-type">>, <<"text/plain">>}], <<"Hello!">>, State}.
%%
%% terminate(_Reason, _State) ->
%%     ok.
%% '''
-module(livery_handler).

-include("livery.hrl").

%% Callbacks

%% @doc Initialize handler state.
%% Called when a new request arrives.
%% Return `{ok, Req, State}' to proceed with handling.
%% Return `{error, Reason}' to abort the request.
-callback init(Req :: #livery_req{}, Opts :: term()) ->
    {ok, #livery_req{}, State :: term()} |
    {error, Reason :: term()}.

%% @doc Handle the request.
%% Return a response tuple to send a response to the client.
-callback handle(Req :: #livery_req{}, State :: term()) ->
    {reply, Status :: non_neg_integer(), Headers :: [{binary(), binary()}],
     Body :: iodata(), NewState :: term()} |
    {reply, Status :: non_neg_integer(), Headers :: [{binary(), binary()}],
     NewState :: term()} |
    {error, Reason :: term(), NewState :: term()}.

%% @doc Clean up handler state.
%% Called when the request processing is finished.
-callback terminate(Reason :: normal | {error, term()}, State :: term()) -> ok.

%% Optional callbacks
-optional_callbacks([terminate/2]).
