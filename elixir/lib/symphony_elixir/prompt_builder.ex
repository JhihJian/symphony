defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    map
    |> with_tracker_context()
    |> Map.new(fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end

  defp with_tracker_context(%{identifier: _identifier} = issue) do
    tracker = Config.settings!().tracker
    tracker_kind = tracker.kind || "unknown"
    closing_reference = closing_reference(issue, tracker)

    issue
    |> Map.put(:tracker_kind, tracker_kind)
    |> Map.put(:closing_reference, closing_reference)
    |> Map.put(:closing_instruction, closing_instruction(tracker_kind, closing_reference))
  end

  defp with_tracker_context(map), do: map

  defp closing_reference(%{identifier: identifier}, %{kind: "github"} = tracker) when is_binary(identifier) do
    provider_closing_reference(identifier, github_scope(tracker))
  end

  defp closing_reference(%{identifier: identifier}, %{kind: "gitlab"} = tracker) when is_binary(identifier) do
    provider_closing_reference(identifier, tracker.project_slug)
  end

  defp closing_reference(%{identifier: identifier}, %{kind: "linear"}) when is_binary(identifier) do
    "Linear: #{identifier}"
  end

  defp closing_reference(%{identifier: identifier}, _tracker) when is_binary(identifier), do: identifier
  defp closing_reference(_issue, _tracker), do: "Unavailable"

  defp provider_closing_reference(identifier, configured_scope) do
    case split_provider_identifier(identifier) do
      {scope, number} when is_binary(scope) and scope == configured_scope ->
        "Closes ##{number}"

      {_scope, _number} ->
        "Closes #{identifier}"

      nil ->
        "Closes #{identifier}"
    end
  end

  defp split_provider_identifier(identifier) do
    case Regex.run(~r/^(.+)#([1-9][0-9]*)$/, identifier) do
      [_match, scope, number] -> {scope, number}
      _ -> nil
    end
  end

  defp github_scope(%{owner: owner, repo: repo}) when is_binary(owner) and is_binary(repo) do
    "#{owner}/#{repo}"
  end

  defp github_scope(_tracker), do: nil

  defp closing_instruction("github", closing_reference) do
    "Use `#{closing_reference}` in the pull request description so GitHub links the PR and closes the issue when it is merged."
  end

  defp closing_instruction("gitlab", closing_reference) do
    "Use `#{closing_reference}` in the merge request description so GitLab links the MR and closes the issue when it is merged."
  end

  defp closing_instruction("linear", closing_reference) do
    "Use `#{closing_reference}` in the pull request description to preserve the Linear ticket reference."
  end

  defp closing_instruction(_tracker_kind, closing_reference) do
    "Use `#{closing_reference}` in the pull request description to preserve the issue reference."
  end
end
