defmodule Mix.Tasks.PrBody.Check do
  use Mix.Task

  alias SymphonyElixir.PullRequestBody

  @shortdoc "Validate PR body format against the repository PR template"

  @moduledoc """
  Validates a PR description markdown file against the structure and expectations
  implied by the repository pull request template.

  Usage:

      mix pr_body.check --file /path/to/pr_body.md
  """

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [file: :string, help: :boolean], aliases: [h: :help])

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        file_path = required_opt(opts, :file)

        case lint_and_print(file_path) do
          :ok ->
            Mix.shell().info("PR body format OK")

          {:error, message} ->
            Mix.raise(message)
        end
    end
  end

  defp required_opt(opts, key) do
    case opts[key] do
      nil -> Mix.raise("Missing required option --#{key}")
      value -> value
    end
  end

  defp lint_and_print(file_path) do
    repo_root = File.cwd!()

    case PullRequestBody.validate_file(file_path, repo_root) do
      :ok ->
        :ok

      {:error, {:read_failed, ^file_path, reason}} ->
        {:error, "Unable to read #{file_path}: #{inspect(reason)}"}

      {:error, {:template_not_found, template_paths}} ->
        {:error, "Unable to read PR template from any of: #{Enum.join(template_paths, ", ")}"}

      {:error, {:invalid, template_path, errors}} ->
        invalid_pr_body_result(template_path, errors)
    end
  end

  defp invalid_pr_body_result(template_path, [message]) when is_binary(message) do
    if String.starts_with?(message, "No markdown headings found") do
      {:error, message}
    else
      Enum.each([message], fn err -> Mix.shell().error("ERROR: #{err}") end)
      {:error, "PR body format invalid. Read `#{template_path}` and follow it precisely."}
    end
  end

  defp invalid_pr_body_result(template_path, errors) do
    Enum.each(errors, fn err -> Mix.shell().error("ERROR: #{err}") end)
    {:error, "PR body format invalid. Read `#{template_path}` and follow it precisely."}
  end
end
