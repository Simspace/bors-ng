use Mix.Config

config :gh, :app_id, {:system, "APP_ID"}
config :gh, :installation_id, {:system, "INSTALLATION_ID"}
config :gh, :pem_file, {:system, "PEM_FILE"}

if Mix.env() == :test do
  import_config "test.exs"
end
