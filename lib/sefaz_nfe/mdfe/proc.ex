defmodule SefazNfe.MDFe.Proc do
  @moduledoc """
  The processed MDF-e documents (NFePHP's `Complements` for sped-mdfe), reached
  through `SefazNfe.Proc` as `mdfe_proc/2`, `mdfe_event_proc/2`,
  `mdfe_cancel_register/2` and `mdfe_close_register/2`.

  | Function | Result | Parts |
  |----------|--------|-------|
  | `mdfe_proc/2` | `mdfeProc` | `MDFe` + `protMDFe` |
  | `mdfe_event_proc/2` | `procEventoMDFe` | `eventoMDFe` + `retEventoMDFe` |
  | `mdfe_cancel_register/2` | the same `mdfeProc` | + the cancellation's `retEventoMDFe` |
  | `mdfe_close_register/2` | the same `mdfeProc` | + the encerramento's `retEventoMDFe` |

  Bytes are spliced, never re-serialised, exactly as in `SefazNfe.Proc` (AD-011):
  the signed `MDFe` (with its `infMDFeSupl`) and SEFAZ's own `protMDFe` or
  `retEventoMDFe` are copied verbatim and wrapped in the MDF-e namespace.

  ## What is checked

    * `mdfe_proc/2`: the `protMDFe` whose `chMDFe` is the document's key (`Id`
      without `MDFe`) and, when both carry one, whose `digVal` is the document's
      `DigestValue`; `cStat` 100 only (MDF-e has no denial).
    * `mdfe_event_proc/2`: the `retEventoMDFe` of the same `chMDFe` and
      `tpEvento`; `cStat` 135 or 136 (and 132 for an encerramento).
    * the registers: `cStat` 135, 136 or 155 (and 132 for an encerramento), the
      right `tpEvento` (110111, or 110112) and the `chMDFe` of the `mdfeProc`.

  Errors are those of `SefazNfe.Proc` with MDF-e names: `:no_protocol`,
  `:no_event`, `:no_event_return`, `:key_mismatch`, `:digest_mismatch`,
  `:no_inf_mdfe`, `{:not_accepted, c_stat}`, `{:not_a_cancellation, tp_evento}`,
  `{:not_a_closure, tp_evento}`, `:not_an_mdfe_proc` and `{:xml, reason}`.
  """

  alias SefazNfe.XML

  @mdfe_ns "http://www.portalfiscal.inf.br/mdfe"
  @declaration ~r/^\s*<\?xml[^>]*\?>/

  @authorized [100]
  @event [135, 136]
  @close_event [135, 136, 132]
  @register [135, 136, 155]
  @close_register [135, 136, 155, 132]

  @type reason :: term()

  @doc """
  `mdfeProc`: the signed `MDFe` and its `protMDFe`, from the answer of the
  authorization or of a consultation.
  """
  @spec mdfe_proc(String.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def mdfe_proc(signed_mdfe_xml, response)
      when is_binary(signed_mdfe_xml) and is_binary(response) do
    with {:ok, doc} <- XML.parse(signed_mdfe_xml),
         {:ok, key, digest} <- document_facts(doc),
         {:ok, protocol} <- protocol_for(response, key, digest),
         :ok <- accepted(protocol, @authorized) do
      {:ok, wrap("mdfeProc", version(doc), [strip(signed_mdfe_xml), protocol.raw])}
    end
  end

  defp document_facts(doc) do
    case XML.attribute(doc, "infMDFe", "Id") do
      "MDFe" <> key -> {:ok, key, XML.text(doc, "DigestValue")}
      _no_id -> {:error, :no_inf_mdfe}
    end
  end

  defp version(doc), do: XML.attribute(doc, "infMDFe", "versao") || "3.00"

  defp protocol_for(response, key, digest) do
    case elements(response, "protMDFe") do
      [] ->
        {:error, :no_protocol}

      protocols ->
        protocols
        |> Enum.map(&facts/1)
        |> Enum.find_value({:error, :key_mismatch}, &protocol_match(&1, key, digest))
    end
  end

  defp protocol_match(%{ch_mdfe: key} = protocol, key, digest) do
    case protocol.dig_val do
      nil -> {:ok, protocol}
      ^digest -> {:ok, protocol}
      _other when is_nil(digest) -> {:ok, protocol}
      _other -> {:error, :digest_mismatch}
    end
  end

  defp protocol_match(_protocol, _key, _digest), do: nil

  @doc """
  `procEventoMDFe`: the signed `eventoMDFe` and the `retEventoMDFe` SEFAZ
  answered it with.
  """
  @spec mdfe_event_proc(String.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def mdfe_event_proc(signed_event_xml, response)
      when is_binary(signed_event_xml) and is_binary(response) do
    with {:ok, event} <- first_element(signed_event_xml, "eventoMDFe", :no_event),
         {:ok, doc} <- XML.parse(event),
         {:ok, returned} <- event_return(response, facts(event)),
         :ok <- accepted(returned, event_c_stats(returned.tp_evento)) do
      {:ok,
       wrap("procEventoMDFe", XML.attribute(doc, "eventoMDFe", "versao") || "3.00", [
         event,
         returned.raw
       ])}
    end
  end

  defp event_c_stats("110112"), do: @close_event
  defp event_c_stats(_tp_evento), do: @event

  defp event_return(response, %{ch_mdfe: key, tp_evento: tp_evento}) do
    case elements(response, "retEventoMDFe") do
      [] ->
        {:error, :no_event_return}

      returns ->
        returns
        |> Enum.map(&facts/1)
        |> Enum.find(&(&1.ch_mdfe == key and &1.tp_evento == tp_evento))
        |> case do
          nil -> {:error, :key_mismatch}
          found -> {:ok, found}
        end
    end
  end

  @doc """
  Marks an authorized `mdfeProc` as cancelled by appending the cancellation's
  `retEventoMDFe` after its `protMDFe` (NFePHP's `cancelRegister`).

  `event_xml` is the `procEventoMDFe` from `mdfe_event_proc/2` or SEFAZ's answer
  itself. Registering the same `retEventoMDFe` again returns the `mdfeProc`
  unchanged. Unlike NFePHP, which returns the document untouched for anything
  else, an answer that does not qualify is an error that says why.
  """
  @spec mdfe_cancel_register(String.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def mdfe_cancel_register(mdfe_proc_xml, event_xml),
    do: register(mdfe_proc_xml, event_xml, "110111", @register, :not_a_cancellation)

  @doc """
  Marks an authorized `mdfeProc` as closed (encerrado) by appending the
  encerramento's `retEventoMDFe` (NFePHP's `closeRegister`). Same rules as
  `mdfe_cancel_register/2` for event 110112, with `{:not_a_closure, tp_evento}`.
  """
  @spec mdfe_close_register(String.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def mdfe_close_register(mdfe_proc_xml, event_xml),
    do: register(mdfe_proc_xml, event_xml, "110112", @close_register, :not_a_closure)

  defp register(proc, event_xml, tp_evento, c_stats, wrong_event)
       when is_binary(proc) and is_binary(event_xml) do
    with {:ok, protocol} <- first_element(proc, "protMDFe", :no_protocol),
         :ok <- closes_with_proc(proc),
         {:ok, returned} <-
           event_of(event_xml, facts(protocol).ch_mdfe, tp_evento, c_stats, wrong_event) do
      {:ok, append(proc, returned.raw)}
    end
  end

  defp closes_with_proc(xml),
    do: if(Regex.match?(~r{</mdfeProc>\s*\z}, xml), do: :ok, else: {:error, :not_an_mdfe_proc})

  defp event_of(event_xml, key, tp_evento, c_stats, wrong_event) do
    case elements(event_xml, "retEventoMDFe") do
      [] ->
        {:error, :no_event_return}

      returns ->
        outcomes = Enum.map(returns, &outcome(facts(&1), key, tp_evento, c_stats, wrong_event))
        Enum.find(outcomes, hd(outcomes), &match?({:ok, _}, &1))
    end
  end

  defp outcome(%{ch_mdfe: key} = returned, key, tp_evento, c_stats, wrong_event) do
    cond do
      returned.tp_evento != tp_evento -> {:error, {wrong_event, returned.tp_evento}}
      returned.c_stat not in c_stats -> {:error, {:not_accepted, returned.c_stat}}
      true -> {:ok, returned}
    end
  end

  defp outcome(_returned, _key, _tp_evento, _c_stats, _wrong_event), do: {:error, :key_mismatch}

  defp append(proc, returned) do
    if String.contains?(proc, returned) do
      proc
    else
      Regex.replace(~r{</mdfeProc>\s*\z}, proc, fn _match -> returned <> "</mdfeProc>" end)
    end
  end

  # Pieces -------------------------------------------------------------------

  defp first_element(xml, name, missing) do
    case elements(xml, name) do
      [element | _more] -> {:ok, element}
      [] -> {:error, missing}
    end
  end

  # Every non-nested `<name ...>...</name>` of `xml`, verbatim. `name` is
  # followed by whitespace, `>` or `/`.
  defp elements(xml, name) do
    ~r{<#{name}(?=[\s>/])(?:[^>]*/>|.*?</#{name}>)}s
    |> Regex.scan(xml)
    |> Enum.map(fn [element] -> element end)
  end

  defp facts(raw) do
    case XML.parse(raw) do
      {:ok, doc} ->
        %{
          raw: raw,
          ch_mdfe: XML.text(doc, "chMDFe"),
          tp_evento: XML.text(doc, "tpEvento"),
          dig_val: XML.text(doc, "digVal"),
          c_stat: XML.integer(doc, "cStat")
        }

      {:error, _reason} ->
        %{raw: raw, ch_mdfe: nil, tp_evento: nil, dig_val: nil, c_stat: nil}
    end
  end

  defp accepted(%{c_stat: c_stat}, accepted) do
    if c_stat in accepted, do: :ok, else: {:error, {:not_accepted, c_stat}}
  end

  defp strip(xml), do: Regex.replace(@declaration, xml, "")

  defp wrap(name, version, parts) do
    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<#{name} xmlns="#{@mdfe_ns}" versao="#{version}">),
      parts,
      "</#{name}>"
    ])
  end
end
