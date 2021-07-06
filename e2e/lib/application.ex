defmodule GH.Application do
  @moduledoc """
  This is just here so you can start the application with iex -S mix
  and have an REPL with the defined modules.
  """

  use Application

  def start(_, _) do
    Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__)
  end
end
