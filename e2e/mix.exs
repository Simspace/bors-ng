defmodule GH.Mixfile do
  use Mix.Project

  def application do
    [mod: {GH.Application, []}, extra_applications: [:confex]]
  end

  def project do
    [
      app: :gh,
      version: "1.0.0",
      deps: deps()
    ]
  end

  defp deps do
    [
      { :joken, "~> 2.0" },
      { :poison, "~> 3.1" },
      { :jason, "~> 1.1" },
      { :jose, "~> 1.11" },
      { :tesla, "~> 1.4.0" },
      { :confex, "~> 3.5.0" }
    ]
  end
end
