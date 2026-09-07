defmodule SefazNfe.Schema do
  @moduledoc """
  Optional XSD validation against the official NF-e schemas.

  Catching a malformed document locally is worth a round trip: SEFAZ answers
  `cStat` 225 with no indication of which element is wrong, while the validator
  names it. It is optional because schemas change with every Nota Técnica, and
  a library that hard-failed on last quarter's XSD would block the very
  documents a reforma update requires.

  ## Configuration

  Off unless a schema directory is configured:

      config :sefaz_nfe, :schemas, "/etc/sefaz/schemas"

  Point it at an unpacked *Pacote de Liberação* from the portal — the directory
  holding `nfe_v4.00.xsd` and its imports. The package vendors none: the zip is
  megabytes, is owned by the RFB, and is versioned by NT rather than by this
  library (AD-004).

  ## Cost

  The schema is compiled on every call. Caching the compiled state looks
  obvious and is wrong: an `:xmerl_xsd` state references ETS tables that
  validation releases, so a cached state validates the first document and then
  reports every later one as "element not in schema". Compiling costs
  milliseconds, and validation is opt-in anyway.
  """

  @type reason :: {:schema, term()}

  @doc """
  Validates `xml` against `schema` — a file name inside the configured
  directory, such as `nfe_v4.00.xsd`.

  Returns `:ok` when validation is off, so a caller can wire this in
  unconditionally and let configuration decide.
  """
  @spec validate(String.t(), String.t()) :: :ok | {:error, reason()}
  def validate(xml, schema) when is_binary(xml) and is_binary(schema) do
    case Application.get_env(:sefaz_nfe, :schemas) do
      nil -> :ok
      directory -> validate(xml, schema, directory)
    end
  end

  @doc "Validates against an explicit schema directory, ignoring configuration."
  @spec validate(String.t(), String.t(), String.t()) :: :ok | {:error, reason()}
  def validate(xml, schema, directory) do
    with {:ok, document} <- SefazNfe.XML.parse(xml),
         {:ok, state} <- schema_state(schema, directory) do
      check(document, state)
    end
  end

  @doc "Whether validation is configured."
  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(Application.get_env(:sefaz_nfe, :schemas))

  # A failure is {:error, reasons}; a success is {validated_element, state}.
  # Matching the error shape first matters: a guard testing elem/2 on the atom
  # :error only fails the guard, and the success clause would then accept every
  # invalid document.
  defp check(document, state) do
    case :xmerl_xsd.validate(document, state) do
      {:error, reasons} -> {:error, {:schema, reasons}}
      {_validated, _state} -> :ok
    end
  rescue
    error -> {:error, {:schema, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:schema, reason}}
  end

  # The schema is compiled per call and deliberately not cached. An
  # :xmerl_xsd state references ETS tables that validation releases, so a state
  # kept in :persistent_term validates once and then reports every document as
  # "element not in schema" — a validator that silently stops validating.
  defp schema_state(schema, directory) do
    path = Path.join(directory, schema)

    # xsdbase is what lets a schema resolve its own imports, which the NF-e
    # package splits across a dozen files.
    case :xmerl_xsd.process_schema(String.to_charlist(path),
           xsdbase: String.to_charlist(directory)
         ) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, {:schema, {:unreadable, path, reason}}}
    end
  rescue
    error -> {:error, {:schema, {:unreadable, schema, Exception.message(error)}}}
  end
end
