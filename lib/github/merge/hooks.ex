defmodule BorsNG.GitHub.Merge.Hooks do
  @moduledoc """
  Runs shell scripts during Bors's merge process.

  Only invoked when local merges are enabled.
  """

  def hooks_dir do
    ".bors-hooks"
  end

  @spec invoke_before_merge_hook!(binary) :: nil
  def invoke_before_merge_hook!(project_dir) do
    hook_file = File.cwd!()
    |> Path.join(project_dir)
    |> Path.join(hooks_dir())
    |> Path.join("before-merge")

    case File.exists?(hook_file) do
      false ->
        nil

      true ->
        System.cmd(hook_file, [], cd: project_dir)
        nil
    end
  end

  @spec invoke_after_merge_hook!(binary) :: nil
  def invoke_after_merge_hook!(project_dir) do
    hook_file = File.cwd!()
    |> Path.join(project_dir)
    |> Path.join(hooks_dir())
    |> Path.join("after-merge")

    case File.exists?(hook_file) do
      false ->
        nil

      true ->
        System.cmd(hook_file, [], cd: project_dir)
        nil
    end
  end
end