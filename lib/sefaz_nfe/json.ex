defimpl JSON.Encoder, for: SefazNfe.Result do
  def encode(result, encoder) do
    encoder.(
      %{
        "status" => result.status,
        "c_stat" => result.c_stat,
        "x_motivo" => result.x_motivo,
        "ch_nfe" => result.ch_nfe,
        "n_prot" => result.n_prot,
        "n_rec" => result.n_rec
      },
      encoder
    )
  end
end
