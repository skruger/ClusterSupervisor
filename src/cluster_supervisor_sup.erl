%%% -------------------------------------------------------------------
%%% Author  : skruger
%%% Description :
%%%
%%% Created : Feb 2, 2011
%%% -------------------------------------------------------------------
-module(cluster_supervisor_sup).

-behaviour(supervisor).
%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------

%% --------------------------------------------------------------------
%% External exports
%% --------------------------------------------------------------------
-export([start_link/1]).

%% --------------------------------------------------------------------
%% Internal exports
%% --------------------------------------------------------------------
-export([
	 init/1
        ]).

%% --------------------------------------------------------------------
%% Macros
%% --------------------------------------------------------------------
-define(SERVER, ?MODULE).

%% --------------------------------------------------------------------
%% Records
%% --------------------------------------------------------------------

%% ====================================================================
%% External functions
%% ====================================================================

start_link(Args) ->
	supervisor:start_link({local,?MODULE},?MODULE,Args).

%% ====================================================================
%% Server functions
%% ====================================================================
%% --------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok,  {SupFlags,  [ChildSpec]}} |
%%          ignore                          |
%%          {error, Reason}
%% --------------------------------------------------------------------
init(_Args) ->
    {ok,{{one_for_one,2,5}, [
							 {cluster_conf,{cluster_conf,start_link,[]},
							  permanent,5000,worker,[]},
							 {cluster_vip,{cluster_supervisor,start_link,[vip]},
							  permanent,5000,worker,[]}
							,
							 {cluster_network_manager,{cluster_network_manager,start_link,[]},
							  permanent,5000,worker,[]}
							 ]}}.

%% ====================================================================
%% Internal functions
%% ====================================================================

