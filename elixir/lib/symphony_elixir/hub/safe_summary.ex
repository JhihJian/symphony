defmodule SymphonyElixir.Hub.SafeSummary do
  @moduledoc """
  Shared Hub summary sanitization.

  Provider-facing summaries may include full issue, comment, PR, prompt, or raw
  response bodies. Hub snapshots keep only safe scalar metadata for those fields
  and drop credential-like fields and values.
  """

  @body_keys MapSet.new([
               "body",
               "comment_body",
               "full_prompt",
               "pull_request_body",
               "pr_body",
               "raw_body",
               "raw_provider_body"
             ])
  @sensitive_keys MapSet.new([
                    "api_key",
                    "apikey",
                    "authorization",
                    "cookie",
                    "credential",
                    "credentials",
                    "env_secret",
                    "env_secrets",
                    "provider_config",
                    "provider_response",
                    "raw_config",
                    "raw_provider_config",
                    "response_body",
                    "secret",
                    "secret_env",
                    "secret_envs",
                    "token",
                    "transcript"
                  ])
  @sensitive_value_patterns [
    ~r/\$[A-Z0-9_]*(TOKEN|API_KEY|SECRET|CREDENTIAL)[A-Z0-9_]*/,
    ~r/\b(api[_-]?key|authorization|bearer|cookie|credential|secret|token|transcript|full prompt|codex transcript)\b/i,
    ~r/\b(ghp_|github_pat_|glpat-|sk-[A-Za-z0-9])/
  ]

  @type sanitize_opts :: [output_keys: :atomize | :preserve, atom_values: :stringify | :preserve]

  @spec sanitize_map(term()) :: map()
  def sanitize_map(value), do: sanitize_map(value, [])

  @spec sanitize_map(term(), sanitize_opts()) :: map()

  def sanitize_map(value, opts) when is_map(value) and is_list(opts) do
    Enum.reduce(value, %{}, fn {raw_key, raw_value}, sanitized ->
      key = normalize_key(raw_key)

      cond do
        body_key?(key) ->
          sanitized
          |> maybe_put(output_key("#{key}_sha256", opts), body_hash(raw_value))
          |> maybe_put(output_key("#{key}_bytes", opts), byte_size_or_nil(raw_value))

        sensitive_key?(key) or sensitive_string?(raw_value) ->
          sanitized

        true ->
          Map.put(sanitized, output_key(raw_key, opts), sanitize_value(raw_value, opts))
      end
    end)
  end

  def sanitize_map(_value, _opts), do: %{}

  @spec sanitize_value(term()) :: term()
  def sanitize_value(value), do: sanitize_value(value, [])

  @spec sanitize_value(term(), sanitize_opts()) :: term()

  def sanitize_value(%DateTime{} = value, _opts), do: DateTime.to_iso8601(value)
  def sanitize_value(%_struct{} = value, _opts), do: value
  def sanitize_value(value, opts) when is_map(value) and is_list(opts), do: sanitize_map(value, opts)

  def sanitize_value(value, opts) when is_list(value) and is_list(opts) do
    value
    |> Enum.reject(&sensitive_string?/1)
    |> Enum.map(&sanitize_value(&1, opts))
  end

  def sanitize_value(value, opts) when is_atom(value) and is_list(opts) do
    case Keyword.get(opts, :atom_values, :stringify) do
      :preserve -> value
      _stringify -> Atom.to_string(value)
    end
  end

  def sanitize_value(value, _opts), do: value

  @spec collect_sensitive_paths(term()) :: [{[String.t()], String.t()}]
  def collect_sensitive_paths(value), do: collect_sensitive_paths(value, [])

  @spec sensitive_key?(term()) :: boolean()
  def sensitive_key?(key) do
    key =
      key
      |> to_string()
      |> String.downcase()

    body_key?(key) or MapSet.member?(@sensitive_keys, key) or
      Regex.match?(~r/(^|_)(token|secret|credential|credentials|cookie|prompt|transcript|raw_config|provider_config|provider_response|response_body)$/, key)
  end

  @spec sensitive_value?(term()) :: boolean()
  def sensitive_value?(value) when is_binary(value), do: sensitive_string?(value)
  def sensitive_value?(%_struct{}), do: false
  def sensitive_value?(value) when is_map(value), do: Enum.any?(value, fn {key, raw_value} -> sensitive_key?(key) or sensitive_value?(raw_value) end)
  def sensitive_value?(value) when is_list(value), do: Enum.any?(value, &sensitive_value?/1)
  def sensitive_value?(_value), do: false

  defp collect_sensitive_paths(%_struct{}, _path), do: []

  defp collect_sensitive_paths(%{} = map, path) do
    Enum.flat_map(map, fn {raw_key, value} ->
      key = raw_key |> normalize_key() |> String.downcase()
      next_path = path ++ [key]

      key_findings =
        if sensitive_key?(key) do
          [{next_path, "field"}]
        else
          []
        end

      key_findings ++ collect_sensitive_paths(value, next_path)
    end)
  end

  defp collect_sensitive_paths(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> collect_sensitive_paths(value, path ++ [Integer.to_string(index)]) end)
  end

  defp collect_sensitive_paths(value, path) when is_binary(value) do
    if sensitive_string?(value) do
      [{path, "value"}]
    else
      []
    end
  end

  defp collect_sensitive_paths(_value, _path), do: []

  defp body_key?(key), do: MapSet.member?(@body_keys, key) or String.ends_with?(key, "_body")

  defp sensitive_string?(value) when is_binary(value) do
    Enum.any?(@sensitive_value_patterns, &Regex.match?(&1, value))
  end

  defp sensitive_string?(_value), do: false

  defp body_hash(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp body_hash(_value), do: nil

  defp byte_size_or_nil(value) when is_binary(value), do: byte_size(value)
  defp byte_size_or_nil(_value), do: nil

  defp output_key(key, opts) do
    case Keyword.get(opts, :output_keys, :atomize) do
      :preserve -> preserve_output_key(key)
      _atomize -> atomize_output_key(key)
    end
  end

  defp preserve_output_key(key) when is_atom(key), do: key
  defp preserve_output_key(key) when is_binary(key), do: key
  defp preserve_output_key(key), do: to_string(key)

  defp atomize_output_key(key) when is_atom(key), do: key

  defp atomize_output_key(key) when is_binary(key) do
    if Regex.match?(~r/\A[a-z_][a-zA-Z0-9_]*\z/, key) do
      String.to_atom(key)
    else
      key
    end
  end

  defp atomize_output_key(key), do: key

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
