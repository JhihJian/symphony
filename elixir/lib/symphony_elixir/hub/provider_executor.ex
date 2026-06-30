defmodule SymphonyElixir.Hub.ProviderExecutor do
  @moduledoc """
  Injectable Hub provider execution boundary.

  The default implementation intentionally stays at the skeleton boundary: it
  accepts a governed provider request and returns a safe provider result without
  calling legacy tracker adapters. Tests and future Hub integrations can inject
  a module or function that performs real provider I/O behind the same request
  contract.
  """

  alias SymphonyElixir.Hub.ProviderGovernance

  @callback execute(ProviderGovernance.request(), keyword()) ::
              ProviderGovernance.result()
              | {:ok, ProviderGovernance.result()}
              | {:error, term()}

  @spec execute(ProviderGovernance.request(), keyword()) :: ProviderGovernance.result()
  def execute(request, opts \\ []) when is_map(request) and is_list(opts) do
    status = Keyword.get(opts, :status, :success)

    ProviderGovernance.result(request, status,
      result_summary: %{
        boundary: "hub_provider_executor",
        executor: "default_skeleton",
        provider_io: false,
        candidate_scan: "accepted"
      }
    )
  end
end
