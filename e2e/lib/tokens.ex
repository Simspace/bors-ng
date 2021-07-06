defmodule Tokens do
  use Joken.Config

  @impl true
  def token_config do
    default_claims(skip: [:iat, :exp])
    |> add_claim("iat", fn -> Joken.current_time-60 end)
    |> add_claim("exp", fn -> Joken.current_time+(10*60) end)
    |> add_claim("iss", fn -> Confex.fetch_env!(:gh, :app_id) end)
  end

  def default_token do
    { _, jwt, _ } = generate_and_sign(%{}, Signing.signer)
    jwt
  end
end
