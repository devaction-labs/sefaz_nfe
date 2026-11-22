defmodule SefazNfe.CTe.Proc do
  @moduledoc """
  The processed CT-e documents that are archived and delivered, assembled the
  way `SefazNfe.Proc` assembles the NF-e's (NFePHP `Complements`), and under the
  same rules (AD-011): the signed document and SEFAZ's answer are copied byte
  for byte out of what the caller passed and wrapped, never parsed and written
  back. The wrapper declares the CT-e namespace, which the answer's elements
  inherit from the SOAP body they were cut from.

  | Function | Result | Parts |
  |----------|--------|-------|
  | `cte_proc/2` | `cteProc` (`cteOSProc` for a `CTeOS`) | `CTe` + `protCTe` |
  | `cte_event_proc/2` | `procEventoCTe` | `eventoCTe` + `retEventoCTe` |
  | `cte_cancel_register/2` | the same `cteProc` | + the cancellation's `retEventoCTe` |

  Each returns `{:ok, xml}` or `{:error, reason}`, with the reasons
  `SefazNfe.Proc` documents (`:no_protocol`, `:no_event_return`,
  `:key_mismatch`, `:digest_mismatch`, `{:not_accepted, c_stat}`,
  `{:not_a_cancellation, tp_evento}`, `{:xml, reason}`), plus
  `:not_a_cte_proc` for `cte_cancel_register/2` of something else.

  ## What is checked

    * `cte_proc/2`: the `protCTe` whose `chCTe` is the document's key (`Id` of
      `infCte` without `CTe`) and, when both carry one, whose `digVal` is the
      document's `DigestValue`; `cStat` 100, 150, 110, 205 or 301 (authorized
      and denied, NFePHP's list; 301 only for a CT-e, never a CT-e OS). A CT-e
      OS (`CTeOS`) becomes a `cteOSProc`.
    * `cte_event_proc/2`: the `retEventoCTe` of the same `chCTe` and `tpEvento`;
      `cStat` 134, 135 or 136, and 155 for a cancellation (110111). 134 is not
      in NFePHP's list: the MOC homologates the event under it too (registered
      with a warning about the CT-e's situation), so it is archived.
    * `cte_cancel_register/2`: `cStat` 135, 136 or 155, `tpEvento` 110111 and
      the `chCTe` of the `cteProc`.
  """

  alias SefazNfe.XML

  @cte_ns "http://www.portalfiscal.inf.br/cte"
  @declaration ~r/^\s*<\?xml[^>]*\?>/

  @cte_c_stats [100, 150, 110, 205, 301]
  @cte_os_c_stats [100, 150, 110, 205]
  @event_c_stats [134, 135, 136]
  @cancel_c_stats [135, 136, 155]
  @cancel_event "110111"

  @type reason :: term()

  @doc """
  `cteProc` (or `cteOSProc`): the signed `CTe` and its `protCTe`, from the
  answer of the authorization or of a consultation.
  """
  @spec cte_proc(String.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def cte_proc(signed_cte_xml, response)
      when is_binary(signed_cte_xml) and is_binary(response) do
    with {:ok, doc} <- XML.parse(signed_cte_xml),
         {:ok, key, digest} <- document_facts(doc),
         {proc, c_stats} = kind(doc),
         {:ok, protocol} <- protocol_for(response, key, digest),
         :ok <- accepted(protocol, c_stats) do
      {:ok, wrap(proc, version(doc), [strip(signed_cte_xml), protocol.raw])}
    end
  end

  defp kind(doc) do
    case XML.element(doc, "CTeOS") do
      nil -> {"cteProc", @cte_c_stats}
      _os -> {"cteOSProc", @cte_os_c_stats}
    end
  end

  defp document_facts(doc) do
    case XML.attribute(doc, "infCte", "Id") do
      "CTe" <> key -> {:ok, key, XML.text(doc, "DigestValue")}
      _no_id -> {:error, :no_inf_cte}
    end
  end

  defp version(doc), do: XML.attribute(doc, "infCte", "versao") || "4.00"

  defp protocol_for(response, key, digest) do
    case elements(response, "protCTe") do
      [] ->
        {:error, :no_protocol}

      protocols ->
        protocols
        |> Enum.map(&facts/1)
        |> Enum.find_value({:error, :key_mismatch}, &protocol_match(&1, key, digest))
    end
  end

  defp protocol_match(%{ch_cte: key} = protocol, key, digest) do
    case protocol.dig_val do
      nil -> {:ok, protocol}
      ^digest -> {:ok, protocol}
      _other when is_nil(digest) -> {:ok, protocol}
      _other -> {:error, :digest_mismatch}
    end
  end

  defp protocol_match(_protocol, _key, _digest), do: nil

  @doc """
  `procEventoCTe`: the signed `eventoCTe` and the `retEventoCTe` SEFAZ answered
  it with.
  """
  @spec cte_event_proc(String.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def cte_event_proc(signed_event_xml, response)
      when is_binary(signed_event_xml) and is_binary(response) do
    with {:ok, event} <- first_element(signed_event_xml, "eventoCTe", :no_event),
         {:ok, doc} <- XML.parse(event),
         {:ok, returned} <- event_return(response, facts(event)),
         :ok <- accepted(returned, event_c_stats(returned.tp_evento)) do
      {:ok,
       wrap("procEventoCTe", XML.attribute(doc, "eventoCTe", "versao") || "4.00", [
         event,
         returned.raw
       ])}
    end
  end

  defp event_c_stats(@cancel_event), do: [155 | @event_c_stats]
  defp event_c_stats(_tp_evento), do: @event_c_stats

  defp event_return(response, %{ch_cte: key, tp_evento: tp_evento}) do
    case elements(response, "retEventoCTe") do
      [] ->
        {:error, :no_event_return}

      returns ->
        returns
        |> Enum.map(&facts/1)
        |> Enum.find(&(&1.ch_cte == key and &1.tp_evento == tp_evento))
        |> case do
          nil -> {:error, :key_mismatch}
          found -> {:ok, found}
        end
    end
  end

  @doc """
  Marks an authorized `cteProc` as cancelled by appending the cancellation's
  `retEventoCTe` after its `protCTe` (NFePHP's `cancelRegister`).

  `event_xml` is the `procEventoCTe` from `cte_event_proc/2` or SEFAZ's answer
  itself; the first `retEventoCTe` that is an accepted cancellation (110111) of
  the `cteProc`'s key is the one appended, spliced as received. Registering the
  same `retEventoCTe` again returns the `cteProc` unchanged. Unlike NFePHP, an
  answer that does not qualify is an error that says why.
  """
  @spec cte_cancel_register(String.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def cte_cancel_register(cte_proc_xml, event_xml)
      when is_binary(cte_proc_xml) and is_binary(event_xml) do
    with {:ok, protocol} <- first_element(cte_proc_xml, "protCTe", :no_protocol),
         {:ok, closing} <- proc_closing(cte_proc_xml),
         {:ok, returned} <- cancellation(event_xml, facts(protocol).ch_cte) do
      {:ok, append(cte_proc_xml, closing, returned.raw)}
    end
  end

  defp proc_closing(xml) do
    case Regex.run(~r{</(cteProc|cteOSProc)>\s*\z}, xml, capture: :all_but_first) do
      [name] -> {:ok, "</#{name}>"}
      nil -> {:error, :not_a_cte_proc}
    end
  end

  defp cancellation(event_xml, key) do
    case elements(event_xml, "retEventoCTe") do
      [] ->
        {:error, :no_event_return}

      returns ->
        outcomes = Enum.map(returns, &cancellation_outcome(facts(&1), key))
        Enum.find(outcomes, hd(outcomes), &match?({:ok, _}, &1))
    end
  end

  defp cancellation_outcome(%{ch_cte: key} = returned, key) do
    cond do
      returned.tp_evento != @cancel_event ->
        {:error, {:not_a_cancellation, returned.tp_evento}}

      returned.c_stat not in @cancel_c_stats ->
        {:error, {:not_accepted, returned.c_stat}}

      true ->
        {:ok, returned}
    end
  end

  defp cancellation_outcome(_returned, _key), do: {:error, :key_mismatch}

  defp append(proc, closing, returned) do
    if String.contains?(proc, returned) do
      proc
    else
      Regex.replace(~r{#{closing}\s*\z}, proc, fn _match -> returned <> closing end)
    end
  end

  # The first element named `name` of `xml`, as the bytes it was written with.
  defp first_element(xml, name, missing) do
    case elements(xml, name) do
      [element | _more] -> {:ok, element}
      [] -> {:error, missing}
    end
  end

  # Every non-nested `<name ...>...</name>` of `xml`, verbatim. `name` is
  # followed by whitespace, `>` or `/`, so `retEventoCTe` never matches a longer
  # name.
  defp elements(xml, name) do
    ~r{<#{name}(?=[\s>])(?:[^>]*/>|.*?</#{name}>)}s
    |> Regex.scan(xml)
    |> Enum.map(fn [element] -> element end)
  end

  defp facts(raw) do
    case XML.parse(raw) do
      {:ok, doc} ->
        %{
          raw: raw,
          ch_cte: XML.text(doc, "chCTe"),
          tp_evento: XML.text(doc, "tpEvento"),
          dig_val: XML.text(doc, "digVal"),
          c_stat: XML.integer(doc, "cStat")
        }

      {:error, _reason} ->
        %{raw: raw, ch_cte: nil, tp_evento: nil, dig_val: nil, c_stat: nil}
    end
  end

  defp accepted(%{c_stat: c_stat}, accepted) do
    if c_stat in accepted, do: :ok, else: {:error, {:not_accepted, c_stat}}
  end

  defp strip(xml), do: Regex.replace(@declaration, xml, "")

  defp wrap(name, version, parts) do
    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<#{name} xmlns="#{@cte_ns}" versao="#{version}">),
      parts,
      "</#{name}>"
    ])
  end
end
