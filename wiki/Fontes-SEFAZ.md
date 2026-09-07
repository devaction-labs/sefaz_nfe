# Fontes oficiais (SEFAZ / RFB)

A tabela de URL e os XSD **não são nossos**. Qualquer snapshot no repo é cópia com data.

## Portal nacional

- [WebServices (produção, por autorizador)](https://www.nfe.fazenda.gov.br/portal/webServices.aspx)  
  Serviços 4.00: `NFeAutorizacao4`, `NFeRetAutorizacao4`, `NFeConsultaProtocolo4`, `NFeStatusServico4`, `NFeRecepcaoEvento4`, `NFeInutilizacao4`.  
  DistDFe (AN): `NFeDistribuicaoDFe` **1.00** — produção `https://www1.nfe.fazenda.gov.br/NFeDistribuicaoDFe/NFeDistribuicaoDFe.asmx`
- [Esquemas XML / pacotes PL](https://www.nfe.fazenda.gov.br/portal/listaConteudo.aspx?tipoConteudo=BMPFMBoln3w=)  
  Inclui PL_010 (NT 2025.002 RTC / IBS-CBS), CNPJ alfanumérico, eventos.
- [Portal principal](https://www.nfe.fazenda.gov.br/portal/principal.aspx)

## Por UF (exemplos; sempre conferir o portal)

- [SEFAZ-SP — URL Web Services NF-e](https://portal.fazenda.sp.gov.br/servicos/nfe/Paginas/URL-WEBSERVICES.aspx)  
  Homologação SP: `https://homologacao.nfe.fazenda.sp.gov.br/ws/nfeautorizacao4.asmx` etc.  
  SVC-AN homolog: `https://hom.svc.fazenda.gov.br/NFeAutorizacao4/NFeAutorizacao4.asmx`
- [SVRS — serviços](https://dfe-portal.svrs.rs.gov.br/Nfe/Servicos) (UFs que usam a virtual)

## Espelho comunitário (não é fonte de verdade)

- [nfephp-org/sped-nfe `storage/wsnfe_4.00_mod55.xml`](https://github.com/nfephp-org/sped-nfe/blob/master/storage/wsnfe_4.00_mod55.xml) — lista de URLs usada por quase todo emissor PHP; **revalidar no portal** antes de cada release.

## O que a lib precisa reler a cada NT

1. Pacote XSD novo no portal de esquemas  
2. Linha nova na tabela de WebServices (URL ou versão)  
3. Manual de Orientação do Contribuinte (assinatura XMLDSig, tamanho de lote, justificativa de evento)

O portal nacional às vezes recusa fetch automatizado. Atualização da tabela = passo manual documentado no release.
