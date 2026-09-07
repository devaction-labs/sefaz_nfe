defmodule SefazNfe.SchemaTest do
  @moduledoc """
  `async: false`: enabling validation sets application environment, and the
  compiled schema is cached in `:persistent_term`.
  """

  use ExUnit.Case, async: false

  alias SefazNfe.Schema

  @ns "http://www.portalfiscal.inf.br/nfe"
  @schemas Path.expand("../fixtures/schemas", __DIR__)

  @valid ~s(<teste xmlns="#{@ns}"><obrigatorio>x</obrigatorio><numero>1</numero></teste>)

  setup do
    on_exit(fn -> Application.delete_env(:sefaz_nfe, :schemas) end)
  end

  test "validation is off until a schema directory is configured" do
    refute Schema.enabled?()
    assert :ok = Schema.validate("<qualquer coisa/>", "minimal_v1.00.xsd")
  end

  test "a conforming document passes" do
    assert :ok = Schema.validate(@valid, "minimal_v1.00.xsd", @schemas)
  end

  test "a missing required element is named, unlike cStat 225" do
    missing = ~s(<teste xmlns="#{@ns}"><numero>1</numero></teste>)

    assert {:error, {:schema, _reason}} = Schema.validate(missing, "minimal_v1.00.xsd", @schemas)
  end

  test "a wrong element order is caught" do
    swapped = ~s(<teste xmlns="#{@ns}"><numero>1</numero><obrigatorio>x</obrigatorio></teste>)

    assert {:error, {:schema, _reason}} = Schema.validate(swapped, "minimal_v1.00.xsd", @schemas)
  end

  test "a wrong datatype is caught" do
    text_where_number =
      ~s(<teste xmlns="#{@ns}"><obrigatorio>x</obrigatorio><numero>abc</numero></teste>)

    assert {:error, {:schema, _reason}} =
             Schema.validate(text_where_number, "minimal_v1.00.xsd", @schemas)
  end

  test "a missing schema file is an error, not a silent pass" do
    assert {:error, {:schema, {:unreadable, _path, _reason}}} =
             Schema.validate(@valid, "nao_existe.xsd", @schemas)
  end

  test "malformed XML is refused before the validator sees it" do
    assert {:error, {:xml, :malformed}} =
             Schema.validate("<nao fechado", "minimal_v1.00.xsd", @schemas)
  end

  test "configuring a directory turns it on for authorize/1" do
    Application.put_env(:sefaz_nfe, :schemas, @schemas)

    assert Schema.enabled?()

    assert {:error, {:schema, _reason}} =
             Schema.validate(~s(<teste xmlns="#{@ns}"/>), "minimal_v1.00.xsd")
  end
end
