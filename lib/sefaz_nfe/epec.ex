defmodule SefazNfe.EPEC do
  @moduledoc """
  Reads, from an NF-e issued in EPEC contingency (`tpEmis` 4), the fields the
  EPEC event (110140) copies from it.

  The document is only read, never modified or re-serialised: it is later
  transmitted to the origin authorizer byte for byte, and the EPEC event
  registered at the Ambiente Nacional has to agree with it value for value.
  Nothing is calculated; `vNF`, `vICMS` and `vST` are the NF-e's own text.

  Reads go through `SefazNfe.XML`, scoped to the element that owns the field
  (`ide`, `emit`, `dest`, `ICMSTot`), so a same-named element elsewhere in the
  document cannot be picked up.
  """

  alias SefazNfe.XML

  @type dest_id :: {:cnpj | :cpf | :id_estrangeiro, String.t()}

  @type t :: %{
          ch_nfe: String.t(),
          tax_id: String.t(),
          epec: %{
            c_uf: String.t(),
            ver_aplic: String.t(),
            dh_emi: String.t(),
            tp_nf: String.t(),
            ie: String.t(),
            dest_uf: String.t(),
            dest_id: dest_id(),
            dest_ie: String.t() | nil,
            v_nf: String.t(),
            v_icms: String.t(),
            v_st: String.t()
          }
        }

  @doc """
  The EPEC facts of `xml`, or the reason it cannot be the subject of one.

  Errors, all before the network:

    * `{:unsupported_for_model, 65}` and `{:unsupported_model, mod}`: EPEC here
      is for model 55;
    * `{:not_epec_document, tp_emis}`: the document is not `tpEmis` 4;
    * `{:epec, :missing_dest}`: EPEC requires a destinatário;
    * `{:epec, {:missing, element}}`: a field the event copies is absent;
    * `{:epec, {:ch_nfe_uf_mismatch, key_uf, c_uf}}`: the first two digits of
      the access key are not `cUF`;
    * `:invalid_ch_nfe`, `:invalid_tax_id`, `{:xml, _}`.

  `:ver_aplic` overrides the `verProc` the event declares.
  """
  @spec extract(term(), keyword()) :: {:ok, t()} | {:error, term()}
  def extract(xml, opts \\ [])

  def extract(xml, opts) when is_binary(xml) do
    with {:ok, doc} <- XML.parse(xml),
         {:ok, ide} <- required_element(doc, "ide"),
         :ok <- model(XML.text(ide, "mod")),
         :ok <- tp_emis(XML.text(ide, "tpEmis")),
         {:ok, dest} <- dest(doc),
         {:ok, emit} <- required_element(doc, "emit"),
         {:ok, totals} <- required_element(doc, "ICMSTot"),
         {:ok, key} <- access_key(XML.attribute(doc, "infNFe", "Id")),
         {:ok, c_uf} <- field(ide, "cUF"),
         :ok <- key_uf(key, c_uf),
         {:ok, tax_id} <- emitter_id(emit),
         {:ok, ie} <- field(emit, "IE"),
         {:ok, dh_emi} <- field(ide, "dhEmi"),
         {:ok, tp_nf} <- field(ide, "tpNF"),
         {:ok, ver_aplic} <- ver_aplic(opts, ide),
         {:ok, dest_uf} <- field(dest, "UF"),
         {:ok, dest_id} <- dest_id(dest),
         {:ok, v_nf} <- field(totals, "vNF"),
         {:ok, v_icms} <- field(totals, "vICMS"),
         {:ok, v_st} <- field(totals, "vST") do
      {:ok,
       %{
         ch_nfe: key,
         tax_id: tax_id,
         epec: %{
           c_uf: c_uf,
           ver_aplic: ver_aplic,
           dh_emi: dh_emi,
           tp_nf: tp_nf,
           ie: ie,
           dest_uf: dest_uf,
           dest_id: dest_id,
           dest_ie: present(XML.text(dest, "IE")),
           v_nf: v_nf,
           v_icms: v_icms,
           v_st: v_st
         }
       }}
    end
  end

  def extract(_xml, _opts), do: {:error, :invalid_xml}

  defp model("55"), do: :ok
  defp model("65"), do: {:error, {:unsupported_for_model, 65}}
  defp model(mod), do: {:error, {:unsupported_model, mod}}

  defp tp_emis("4"), do: :ok
  defp tp_emis(tp_emis), do: {:error, {:not_epec_document, tp_emis}}

  defp dest(doc) do
    case XML.element(doc, "dest") do
      nil -> {:error, {:epec, :missing_dest}}
      dest -> {:ok, dest}
    end
  end

  defp required_element(doc, name) do
    case XML.element(doc, name) do
      nil -> {:error, {:epec, {:missing, name}}}
      element -> {:ok, element}
    end
  end

  defp access_key("NFe" <> key) when byte_size(key) == 44 do
    if String.match?(key, ~r/^\d{44}$/), do: {:ok, key}, else: {:error, :invalid_ch_nfe}
  end

  defp access_key(_id), do: {:error, :invalid_ch_nfe}

  defp key_uf(<<key_uf::binary-size(2), _rest::binary>>, c_uf) do
    if key_uf == c_uf, do: :ok, else: {:error, {:epec, {:ch_nfe_uf_mismatch, key_uf, c_uf}}}
  end

  defp emitter_id(emit) do
    case {present(XML.text(emit, "CNPJ")), present(XML.text(emit, "CPF"))} do
      {nil, nil} -> {:error, :invalid_tax_id}
      {cnpj, nil} -> {:ok, cnpj}
      {_cnpj, cpf} -> {:ok, cpf}
    end
  end

  defp dest_id(dest) do
    case {XML.text(dest, "CNPJ"), XML.text(dest, "CPF"), XML.text(dest, "idEstrangeiro")} do
      {cnpj, _, _} when cnpj not in [nil, ""] -> {:ok, {:cnpj, cnpj}}
      {_, cpf, _} when cpf not in [nil, ""] -> {:ok, {:cpf, cpf}}
      {_, _, id} when id not in [nil, ""] -> {:ok, {:id_estrangeiro, id}}
      _none -> {:error, {:epec, {:missing, "dest/CNPJ|CPF|idEstrangeiro"}}}
    end
  end

  defp ver_aplic(opts, ide) do
    case Keyword.fetch(opts, :ver_aplic) do
      {:ok, ver} when is_binary(ver) and ver != "" -> {:ok, ver}
      _default -> field(ide, "verProc")
    end
  end

  defp field(element, name) do
    case present(XML.text(element, name)) do
      nil -> {:error, {:epec, {:missing, name}}}
      value -> {:ok, value}
    end
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(text), do: text
end
