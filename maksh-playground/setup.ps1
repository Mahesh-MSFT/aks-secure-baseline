# Create a self-signed root certificate for Agw
$agwrootcert = New-SelfSignedCertificate -Type Custom -KeySpec Signature `
-Subject "CN=bicycle.contoso.com/O=Contoso Bicycle" -KeyExportPolicy Exportable `
-HashAlgorithm sha256 -KeyLength 2048 `
-CertStoreLocation "Cert:\CurrentUser\My" -KeyUsageProperty Sign -KeyUsage CertSign

# Generate a client certificate for Agw
$agwClientCert = New-SelfSignedCertificate -Type Custom -DnsName makshP2SChildCert -KeySpec Signature `
-Subject "CN=bicycle.contoso.com/O=Contoso Bicycle" -KeyExportPolicy Exportable `
-HashAlgorithm sha256 -KeyLength 2048 `
-CertStoreLocation "Cert:\CurrentUser\My" `
-Signer $agwrootcert -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.2")

# Export Agw client certificate
$agwcertclientpwd = ConvertTo-SecureString -String "1234" -Force -AsPlainText
Export-PfxCertificate -Password $agwcertclientpwd `
    -Cert (get-item -Path Cert:\CurrentUser\My\$($agwClientCert.Thumbprint)) `
    -FilePath "C:\Users\maksh\OneDrive - Microsoft\Code\aks-secure-baseline\maksh-playground\agw-aks.pfx"


$APP_GATEWAY_LISTENER_CERTIFICATE = Get-ChildItem Cert:\CurrentUser\My\ -Recurse | Where-Object { $_.Subject -like '*bicycle.contoso.com/O=Contoso Bicycle'}

# Get Base64 encoded raw certificate data to be used in ARM Template
#$([Convert]::ToBase64String($agwrootcert.Export('Cert')))
#$([Convert]::ToBase64String($agwrootcert.Export('Cert'), [System.Base64FormattingOptions]::InsertLineBreaks))

# Create a self-signed root certificate for Ingress
$ingressrootcert = New-SelfSignedCertificate -Type Custom -KeySpec Signature `
-Subject "CN=bicycle.contoso.com/O=Contoso Bicycle" -KeyExportPolicy Exportable `
-HashAlgorithm sha256 -KeyLength 2048 `
-CertStoreLocation "Cert:\CurrentUser\My" -KeyUsageProperty Sign -KeyUsage CertSign

