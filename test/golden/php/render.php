<?php
// Golden reference renderer for the sefaz_nfe builder tests (T5).
//
// Runs the gateway's REAL App\Pipelines\Nfe\BuildNfeXml (NFePHP Make) standalone: no Laravel
// app, no database. The Company model is hydrated in memory with forceFill (never saved), and
// the NfeIssuanceContext is assembled from test/golden/contexts/<name>.json.
//
// Source of the reference logic: fiscal-gateway app/Pipelines/Nfe/BuildNfeXml.php
// gateway git sha: 74ef5622aa16d6db5a2d9cd22946edf86d9deb7b
// (the sha is also written to test/golden/expected/GATEWAY_SHA so drift is detectable)
//
// Usage: php -d detect_unicode=0 render.php <gateway-root> <golden-dir> [name ...]
// Determinism: cNF, dhEmi, series, number, model, tpEmis, tpAmb all come from the context file.

declare(strict_types=1);

use App\Enums\EmissionType;
use App\Enums\FiscalDocumentModel;
use App\Enums\FiscalEnvironment;
use App\Enums\TaxRegime;
use App\Models\Company;
use App\Pipelines\Nfe\BuildNfeXml;
use App\Support\Nfe\NfeIssuanceContext;
use Carbon\CarbonImmutable;

$gateway = rtrim($argv[1], '/');
$golden = rtrim($argv[2], '/');

// The gateway's composer.json requires PHP >= 8.6; vendor/autoload.php would refuse to run on an
// older runtime (platform_check.php). Build the same class loader without that check.
$vendor = $gateway.'/vendor';
require $vendor.'/composer/ClassLoader.php';
$loader = new Composer\Autoload\ClassLoader($vendor);
foreach (require $vendor.'/composer/autoload_psr4.php' as $ns => $dirs) {
    $loader->setPsr4($ns, $dirs);
}
foreach (require $vendor.'/composer/autoload_namespaces.php' as $ns => $dirs) {
    $loader->set($ns, $dirs);
}
$loader->addClassMap(require $vendor.'/composer/autoload_classmap.php');
$loader->register(true);
foreach (require $vendor.'/composer/autoload_files.php' as $file) {
    require_once $file;
}


$names = array_slice($argv, 3);
if ($names === []) {
    foreach (glob($golden.'/payloads/*.json') as $file) {
        $names[] = basename($file, '.json');
    }
}

foreach ($names as $name) {
    $payload = json_decode(file_get_contents("$golden/payloads/$name.json"), true, flags: JSON_THROW_ON_ERROR);
    $ctx = json_decode(file_get_contents("$golden/contexts/$name.json"), true, flags: JSON_THROW_ON_ERROR);
    if (! in_array($ctx['model'], [55, 65], true)) {
        continue; // CT-e / CT-e OS / MDF-e: render_cte_mdfe.php
    }

    $company = (new Company)->forceFill($ctx['company']);
    $company->tax_regime = TaxRegime::from($ctx['company']['tax_regime']);

    $context = new NfeIssuanceContext(
        company: $company,
        environment: FiscalEnvironment::from($ctx['environment']),
        model: FiscalDocumentModel::from($ctx['model']),
        series: $ctx['series'],
        number: $ctx['number'],
        numericCode: $ctx['numeric_code'],
        emissionType: EmissionType::from($ctx['emission_type']),
        payload: $payload,
        issuedAt: CarbonImmutable::parse($ctx['issued_at']),
    );

    $built = (new BuildNfeXml)->handle($context, fn (NfeIssuanceContext $c): NfeIssuanceContext => $c);
    file_put_contents("$golden/expected/$name.xml", $built->xml);
    echo "$name ok ".$built->accessKey->value."\n";
}
