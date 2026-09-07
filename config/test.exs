import Config

# `mix test` never opens a socket (a success criterion of the spec). This is
# enforced here rather than left to each test remembering to stub: the default
# client is the real mTLS one, so only config keeps the suite offline.
config :sefaz_nfe, :soap, SefazNfe.SOAP.NotImplemented
