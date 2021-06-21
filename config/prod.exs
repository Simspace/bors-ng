use Mix.Config

config :bors, :server, BorsNG.GitHub.Server
config :bors, :oauth2, BorsNG.GitHub.OAuth2

config :bors, :local_merge?, {:system, :boolean, "USE_LOCAL_MERGE", false}

import_config "prod.secret.exs"
