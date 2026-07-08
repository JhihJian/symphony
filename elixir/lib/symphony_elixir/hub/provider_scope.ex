defmodule SymphonyElixir.Hub.ProviderScope do
  @moduledoc """
  Provider scope summaries for Hub project identity and issue references.
  """

  @supported_kinds MapSet.new(["github", "gitlab", "linear", "memory"])

  @type t :: %{
          required(:kind) => String.t(),
          required(:scope) => map(),
          required(:key) => String.t()
        }

  @spec from_tracker(String.t(), term()) :: {:ok, t()} | {:error, term()}
  def from_tracker(project_id, tracker_like) when is_binary(project_id) do
    tracker = tracker_payload(tracker_like)
    kind = tracker |> Map.get("kind") |> normalize_optional_string()

    cond do
      is_nil(kind) ->
        {:error, :missing_tracker_kind}

      not MapSet.member?(@supported_kinds, kind) ->
        {:error, {:unsupported_tracker_kind, kind}}

      true ->
        scope_for_kind(project_id, kind, tracker)
    end
  end

  @spec supported_kind?(term()) :: boolean()
  def supported_kind?(kind) when is_binary(kind), do: MapSet.member?(@supported_kinds, kind)
  def supported_kind?(kind) when is_atom(kind), do: kind |> Atom.to_string() |> supported_kind?()
  def supported_kind?(_kind), do: false

  @spec tracker_payload(term()) :: map()
  def tracker_payload(%_struct{} = struct), do: struct |> Map.from_struct() |> normalize_keys()

  def tracker_payload(%{} = config) do
    config = normalize_keys(config)

    cond do
      is_map(Map.get(config, "tracker")) ->
        Map.get(config, "tracker")

      is_map(Map.get(config, "tracker_summary")) ->
        Map.get(config, "tracker_summary")

      true ->
        config
    end
  end

  def tracker_payload(_config), do: %{}

  defp scope_for_kind(_project_id, "github", tracker) do
    owner = tracker |> Map.get("owner") |> normalize_optional_string()
    repo = tracker |> Map.get("repo") |> normalize_optional_string()
    project_number = Map.get(tracker, "project_number")

    cond do
      is_nil(owner) ->
        {:error, :missing_github_owner}

      is_nil(repo) ->
        {:error, :missing_github_repo}

      true ->
        scope =
          %{
            owner: owner,
            repo: repo
          }
          |> maybe_put_project_number(project_number)

        {:ok, %{kind: "github", scope: scope, key: "github:" <> downcase_scope("#{owner}/#{repo}")}}
    end
  end

  defp scope_for_kind(_project_id, kind, tracker) when kind in ["gitlab", "linear"] do
    project_slug = tracker |> Map.get("project_slug") |> normalize_optional_string()

    if is_nil(project_slug) do
      {:error, if(kind == "gitlab", do: :missing_gitlab_project_slug, else: :missing_linear_project_slug)}
    else
      {:ok, %{kind: kind, scope: %{project_slug: project_slug}, key: kind <> ":" <> downcase_scope(project_slug)}}
    end
  end

  defp scope_for_kind(project_id, "memory", tracker) do
    namespace =
      tracker
      |> Map.get("namespace")
      |> normalize_optional_string()
      |> Kernel.||(project_id)

    {:ok, %{kind: "memory", scope: %{namespace: namespace}, key: "memory:" <> namespace}}
  end

  defp maybe_put_project_number(scope, project_number) when is_integer(project_number) do
    Map.put(scope, :project_number, project_number)
  end

  defp maybe_put_project_number(scope, _project_number), do: scope

  defp normalize_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp downcase_scope(value) when is_binary(value), do: String.downcase(value)

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
