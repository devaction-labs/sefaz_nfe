defmodule SefazNfe.Signer do
  @moduledoc """
  Enveloped XMLDSig, as the MOC 4.00 defines it for NF-e.

  ## Algorithms

  RSA-SHA1 and SHA-1, with Canonical XML 1.0. SHA-1 is weak everywhere else and
  is nonetheless what the MOC prescribes here; SEFAZ rejects anything stronger,
  so this is compatibility, not a recommendation. Confirm the annex against the
  current MOC before assuming it changed.

  ## What gets signed

  One `Reference`, pointing at the `Id` of the element being signed — `infNFe`
  for a document, `infEvento` for cancel and CCe, `infInut` for a number range.
  Two transforms: enveloped-signature, then C14N.

  ## Insertion

  The signature is spliced into the original bytes rather than produced by
  re-serialising the parsed tree. The ERP owns that XML and SEFAZ digests what
  it receives; rewriting it — reordering an attribute, collapsing an empty
  element — would invalidate the very signature being added, and would break
  SEFAZ-04's promise that tax nodes arrive untouched.

  A document that already carries a `Signature` is returned as it is, because
  the MOC signs a document once.
  """

  alias SefazNfe.Certificate
  alias SefazNfe.XML
  alias SefazNfe.XML.C14N

  @dsig_ns "http://www.w3.org/2000/09/xmldsig#"
  @c14n "http://www.w3.org/TR/2001/REC-xml-c14n-20010315"
  @enveloped "http://www.w3.org/2000/09/xmldsig#enveloped-signature"
  @rsa_sha1 "http://www.w3.org/2000/09/xmldsig#rsa-sha1"
  @sha1 "http://www.w3.org/2000/09/xmldsig#sha1"

  @signature ~r/<(?:[\w.-]+:)?Signature[\s>]/

  @doc """
  Signs the `infNFe` of an NF-e, returning the document with the `Signature`
  appended inside `NFe`.
  """
  @spec sign_nfe(String.t(), Certificate.t()) :: {:ok, String.t()} | {:error, term()}
  def sign_nfe(xml, %Certificate{} = cert) when is_binary(xml) do
    sign(xml, cert, "infNFe", "NFe")
  end

  @doc """
  Signs any of the MOC's signable elements.

  `tag` is the element carrying the `Id` (`infNFe`, `infEvento`, `infInut`) and
  `parent` the element the `Signature` belongs to.
  """
  @spec sign(String.t(), Certificate.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def sign(xml, %Certificate{} = cert, tag, parent) when is_binary(xml) do
    if signed?(xml) do
      {:ok, xml}
    else
      build(xml, cert, tag, parent)
    end
  end

  @doc "Whether `xml` already carries an XMLDSig `Signature`, prefixed or not."
  @spec signed?(String.t()) :: boolean()
  def signed?(xml) when is_binary(xml), do: Regex.match?(@signature, xml)

  defp build(xml, cert, tag, parent) do
    with {:ok, doc} <- XML.parse(xml),
         {:ok, element} <- find(doc, tag),
         {:ok, id} <- reference_id(doc, tag) do
      digest = element |> C14N.canonicalize() |> hash() |> Base.encode64()
      signed_info = signed_info(id, digest)

      with {:ok, signature_value} <- sign_info(signed_info, cert) do
        signature = signature(signed_info, signature_value, cert)
        splice(xml, parent, signature)
      end
    end
  end

  defp find(doc, tag) do
    case XML.element(doc, tag) do
      nil -> {:error, {:signer, {:missing_element, tag}}}
      element -> {:ok, element}
    end
  end

  defp reference_id(doc, tag) do
    case XML.attribute(doc, tag, "Id") do
      nil -> {:error, {:signer, {:missing_id, tag}}}
      id -> {:ok, id}
    end
  end

  defp signed_info(id, digest) do
    ~s(<SignedInfo xmlns="#{@dsig_ns}">) <>
      ~s(<CanonicalizationMethod Algorithm="#{@c14n}"></CanonicalizationMethod>) <>
      ~s(<SignatureMethod Algorithm="#{@rsa_sha1}"></SignatureMethod>) <>
      ~s(<Reference URI="##{id}">) <>
      ~s(<Transforms>) <>
      ~s(<Transform Algorithm="#{@enveloped}"></Transform>) <>
      ~s(<Transform Algorithm="#{@c14n}"></Transform>) <>
      ~s(</Transforms>) <>
      ~s(<DigestMethod Algorithm="#{@sha1}"></DigestMethod>) <>
      ~s(<DigestValue>#{digest}</DigestValue>) <>
      ~s(</Reference></SignedInfo>)
  end

  # SignedInfo is signed in its canonical form, which is what a verifier
  # recomputes. Building it and canonicalising the parse keeps the two in step
  # instead of trusting the string to already be canonical.
  defp sign_info(signed_info, cert) do
    with {:ok, doc} <- XML.parse(signed_info) do
      canonical = C14N.canonicalize(doc)
      key = :public_key.der_decode(:PrivateKeyInfo, cert.key)
      {:ok, Base.encode64(:public_key.sign(canonical, :sha, key))}
    end
  end

  defp signature(signed_info, signature_value, cert) do
    inner = String.replace(signed_info, ~s( xmlns="#{@dsig_ns}"), "", global: false)

    ~s(<Signature xmlns="#{@dsig_ns}">) <>
      inner <>
      ~s(<SignatureValue>#{signature_value}</SignatureValue>) <>
      ~s(<KeyInfo><X509Data><X509Certificate>) <>
      Base.encode64(cert.der) <>
      ~s(</X509Certificate></X509Data></KeyInfo></Signature>)
  end

  # `return: :index` counts bytes, so the split has to as well. An accented
  # character before the closing tag makes graphemes and bytes disagree.
  defp splice(xml, parent, signature) do
    closing = ~r/<\/(?:[\w.-]+:)?#{Regex.escape(parent)}>/

    case Regex.run(closing, xml, return: :index) do
      [{at, _length}] ->
        {:ok, binary_part(xml, 0, at) <> signature <> binary_part(xml, at, byte_size(xml) - at)}

      nil ->
        {:error, {:signer, {:missing_element, parent}}}
    end
  end

  defp hash(canonical), do: :crypto.hash(:sha, canonical)
end
