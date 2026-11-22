defmodule SefazNfe.CStat do
  @moduledoc """
  Classifies a SEFAZ `cStat` into what the host has to do about it.

  This is classification, not translation: the library does not ship a `cStat`
  dictionary, and the `xMotivo` SEFAZ sends is the text to show. What the host
  cannot get from `xMotivo` is the decision, so the codes whose consequence the
  MOC 4.00 fixes are named here and every other code falls back to its range.

  | Status | Codes | Why |
  |--------|-------|-----|
  | `:authorized` | 100, 150 | NF-e authorized (150: outside the deadline) |
  | | 102 | number range voided (inutilização homologada) |
  | | 134, 135, 136, 155 | event registered (134: with a warning about the document's situation; 155: cancellation homologated outside the deadline) |
  | | 124 | EPEC authorized |
  | `:denied` | 110, 301, 302, 303 | uso denegado: the document exists and must be stored; the number is consumed, never retry with it and never reuse it |
  | `:cancelled` | 101, 151 | a consultation found the NF-e cancelled |
  | `:closed` | 132 | a consultation found the MDF-e encerrado (closed): terminal, like `:cancelled` |
  | `:in_operation` | 107 | service status answer: the service is up (not a rejection) |
  | `:batch_received` | 103 | lote received, collect with the recibo |
  | `:batch_processed` | 104, 128 | lote (128: event lote) processed, the outcome is per item |
  | `:processing` | 105 | lote still being processed, ask again later |
  | `:retryable` | 108, 109 | service paused (momentarily / without forecast) |
  | | 656 | consumo indevido: wait at least 1 hour before asking again |
  | | 999 | uncatalogued error on SEFAZ's side |
  | `:rejected` | every other code | 200..999 (minus the above) and any unknown 1xx: definitive, fix the document and send again |

  ## CT-e (models 57 and 67)

  The CT-e MOC 4.00 uses the same codes with the same consequence (100, 101,
  110, 134, 135, 136, 107, 108, 109 and 301 included) except one:
  678 is "Consumo Indevido" for CT-e, where for NF-e it is an ordinary
  rejection (NF referenciada com UF diferente). `classify/1` cannot tell them
  apart, so `classify/2` takes the model: 678 under 57 or 67 is `:retryable`
  (wait about an hour, like 656), and every other code is `classify/1`.
  `SefazNfe.CTe` classifies with it.

  On `:retryable` the same request may be sent again later, unchanged. For an
  authorization, consult by key first: SEFAZ may have processed the document
  despite the answer, and a resend would then come back as 204 (duplicidade).
  On `:rejected` the request itself is wrong and must change before it is sent
  again.
  """

  @type status ::
          :authorized
          | :denied
          | :cancelled
          | :closed
          | :in_operation
          | :batch_received
          | :batch_processed
          | :processing
          | :retryable
          | :rejected

  @authorized [100, 102, 124, 134, 135, 136, 150, 155]
  @denied [110, 301, 302, 303]
  @cancelled [101, 151]
  @batch_processed [104, 128]
  @retryable [108, 109, 656, 999]

  @doc """
  Maps a `cStat` to its `t:status/0`. Unknown codes are `:rejected`.
  """
  @spec classify(pos_integer()) :: status()
  def classify(c_stat) when c_stat in @authorized, do: :authorized
  def classify(c_stat) when c_stat in @denied, do: :denied
  def classify(c_stat) when c_stat in @cancelled, do: :cancelled
  def classify(132), do: :closed
  def classify(107), do: :in_operation
  def classify(103), do: :batch_received
  def classify(c_stat) when c_stat in @batch_processed, do: :batch_processed
  def classify(105), do: :processing
  def classify(c_stat) when c_stat in @retryable, do: :retryable
  def classify(c_stat) when is_integer(c_stat) and c_stat > 0, do: :rejected

  @doc """
  `classify/1` for a document model. Only CT-e (57, 67) differs: 678 is
  `:retryable` there (Consumo Indevido). See the moduledoc.
  """
  @spec classify(pos_integer(), pos_integer()) :: status()
  def classify(678, model) when model in [57, 67], do: :retryable
  def classify(c_stat, _model), do: classify(c_stat)
end
