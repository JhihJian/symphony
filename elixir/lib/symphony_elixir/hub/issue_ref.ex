defmodule SymphonyElixir.Hub.IssueRef do
  @moduledoc """
  Provider-neutral issue reference boundary for future Hub ledgers and queues.
  """

  alias SymphonyElixir.Hub.ProviderScope
  alias SymphonyElixir.Linear.Issue

  defstruct [
    :project_id,
    :tracker_kind,
    :provider_scope,
    :provider_scope_key,
    :provider_issue_id,
    :provider_local_id,
    :identifier,
    :url
  ]

  @type t :: %__MODULE__{
          project_id: String.t(),
          tracker_kind: String.t(),
          provider_scope: map(),
          provider_scope_key: String.t(),
          provider_issue_id: String.t() | nil,
          provider_local_id: String.t() | nil,
          identifier: String.t() | nil,
          url: String.t() | nil
        }

  @spec from_issue(String.t(), map() | struct(), Issue.t() | map()) :: {:ok, t()} | {:error, term()}
  def from_issue(project_id, tracker_like, issue_like) when is_binary(project_id) do
    with {:ok, provider_scope} <- ProviderScope.from_tracker(project_id, tracker_like),
         issue <- normalize_issue(issue_like),
         {:ok, provider_issue_id, provider_local_id} <- issue_identity(provider_scope.kind, issue) do
      {:ok,
       %__MODULE__{
         project_id: project_id,
         tracker_kind: provider_scope.kind,
         provider_scope: provider_scope.scope,
         provider_scope_key: provider_scope.key,
         provider_issue_id: provider_issue_id,
         provider_local_id: provider_local_id,
         identifier: normalize_optional_string(Map.get(issue, "identifier")),
         url: normalize_optional_string(Map.get(issue, "url"))
       }}
    end
  end

  @spec key(t()) :: String.t()
  def key(%__MODULE__{} = issue_ref) do
    [
      issue_ref.project_id,
      issue_ref.provider_scope_key,
      issue_ref.provider_issue_id || issue_ref.provider_local_id || issue_ref.identifier
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
  end

  defp issue_identity("github", issue) do
    provider_issue_id = issue |> Map.get("id") |> normalize_optional_string()
    provider_local_id = first_present(issue, ["number", "issue_number", "iid"])

    if is_nil(provider_issue_id) and is_nil(provider_local_id) do
      {:error, :missing_issue_identity}
    else
      {:ok, provider_issue_id, provider_local_id}
    end
  end

  defp issue_identity("gitlab", issue) do
    provider_issue_id = issue |> Map.get("id") |> normalize_optional_string()
    provider_local_id = first_present(issue, ["iid", "number", "issue_number"])

    if is_nil(provider_issue_id) and is_nil(provider_local_id) do
      {:error, :missing_issue_identity}
    else
      {:ok, provider_issue_id, provider_local_id}
    end
  end

  defp issue_identity(kind, issue) when kind in ["linear", "memory"] do
    provider_issue_id = issue |> Map.get("id") |> normalize_optional_string()
    provider_local_id = issue |> Map.get("identifier") |> normalize_optional_string()

    if is_nil(provider_issue_id) and is_nil(provider_local_id) do
      {:error, :missing_issue_identity}
    else
      {:ok, provider_issue_id, provider_local_id}
    end
  end

  defp normalize_issue(%Issue{} = issue), do: issue |> Map.from_struct() |> normalize_keys()
  defp normalize_issue(%_struct{} = issue), do: issue |> Map.from_struct() |> normalize_keys()
  defp normalize_issue(%{} = issue), do: normalize_keys(issue)

  defp first_present(issue, keys) do
    Enum.find_value(keys, fn key ->
      issue
      |> Map.get(key)
      |> issue_local_id_string()
    end)
  end

  defp issue_local_id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp issue_local_id_string(value), do: normalize_optional_string(value)

  defp normalize_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_optional_string(_value), do: nil

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)
end
