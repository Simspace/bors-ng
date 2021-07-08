defmodule Signing do
  def rsa_key do
    { _, key_map } = Confex.fetch_env!(:gh, :pem_file)
      |> JOSE.JWK.from_pem_file()
      |> JOSE.JWK.to_map
    key_map
  end

  def signer do
    Joken.Signer.create("RS256", rsa_key())
  end
end
