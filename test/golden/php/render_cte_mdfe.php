<?php
// Golden reference renderer for CT-e, CT-e OS and MDF-e (task C6, .specs/features/cte-mdfe).
//
// Runs the gateway's REAL pipeline steps standalone: no Laravel app, no database.
//   * App\Pipelines\Cte\BuildCteXml      (NFePHP\CTe\MakeCTe)
//   * App\Pipelines\Cte\BuildCteOsXml    (NFePHP\CTe\MakeCTeOS)
//   * App\Pipelines\Mdfe\BuildMdfeXml    (NFePHP\MDFe\Make)
// The Company model is hydrated in memory with forceFill (never saved) and the issuance
// context is assembled from test/golden/contexts/<name>.json; the payload is
// test/golden/payloads/<name>.json. The step is chosen by the context's `model`
// (57 CT-e, 67 CT-e OS, 58 MDF-e); contexts of any other model (the NF-e/NFC-e ones,
// which belong to render.php) are skipped.
//
// gateway git sha: 74ef5622aa16d6db5a2d9cd22946edf86d9deb7b (also in expected/GATEWAY_SHA)
//
// Usage: php -d detect_unicode=0 render_cte_mdfe.php <gateway-root> <golden-dir> [name ...]
//
// Determinism. The three steps draw their random code with NFePHP\Common\Keys::random()
// (cCT / cMDF); that is the only non-deterministic input. This script defines
// NFePHP\Common\Keys itself, from the vendored source, with random() returning the
// context's `numeric_code`; the vendored file and the gateway are not touched. The issue
// time, series, number, model, tpAmb and tpEmis come from the context. The MDF-e
// infRespTec comes from config('fiscal.mdfe.responsible_technical') (env in production):
// an in-memory config repository is bound from the context's optional `responsible_technical`.

declare(strict_types=1);

use App\Enums\EmissionType;
use App\Enums\FiscalDocumentModel;
use App\Enums\FiscalEnvironment;
use App\Enums\TaxRegime;
use App\Models\Company;
use App\Pipelines\Cte\BuildCteOsXml;
use App\Pipelines\Cte\BuildCteXml;
use App\Pipelines\Mdfe\BuildMdfeXml;
use App\Support\Cte\CteIssuanceContext;
use App\Support\Mdfe\MdfeIssuanceContext;
use Carbon\CarbonImmutable;
use Illuminate\Config\Repository;
use Illuminate\Container\Container;

$gateway = rtrim($argv[1], '/');
$golden = rtrim($argv[2], '/');

// composer.json requires PHP >= 8.6; vendor/autoload.php refuses older runtimes
// (platform_check.php). Build the same class loader without that check.
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

// Keys with a deterministic random(): the vendored class, one early return added.
$keys = file_get_contents($vendor.'/nfephp-org/sped-common/src/Keys.php');
$patched = str_replace(
    "public static function random(\$nnf = null)\n    {",
    "public static function random(\$nnf = null)\n    {\n        if (isset(\$GLOBALS['golden_numeric_code'])) { return \$GLOBALS['golden_numeric_code']; }",
    $keys,
    $count,
);
if ($count !== 1) {
    fwrite(STDERR, "cannot patch Keys::random\n");
    exit(1);
}
eval('?>'.$patched);

$none = ['cnpj' => null, 'contact_name' => null, 'email' => null, 'phone' => null];
$config = new Repository(['fiscal' => ['mdfe' => ['responsible_technical' => $none]]]);
Container::getInstance()->instance('config', $config);

$names = array_slice($argv, 3);
if ($names === []) {
    foreach (glob($golden.'/contexts/*.json') as $file) {
        $names[] = basename($file, '.json');
    }
}

$steps = [57 => BuildCteXml::class, 67 => BuildCteOsXml::class, 58 => BuildMdfeXml::class];

foreach ($names as $name) {
    $ctx = json_decode(file_get_contents("$golden/contexts/$name.json"), true, flags: JSON_THROW_ON_ERROR);
    if (! isset($steps[$ctx['model']])) {
        continue;
    }
    $payload = json_decode(file_get_contents("$golden/payloads/$name.json"), true, flags: JSON_THROW_ON_ERROR);

    $GLOBALS['golden_numeric_code'] = $ctx['numeric_code'];
    $config->set('fiscal.mdfe.responsible_technical', $ctx['responsible_technical'] ?? $none);

    $company = (new Company)->forceFill($ctx['company']);
    $company->tax_regime = TaxRegime::from($ctx['company']['tax_regime']);

    $args = [
        'company' => $company,
        'environment' => FiscalEnvironment::from($ctx['environment']),
        'model' => FiscalDocumentModel::from($ctx['model']),
        'series' => $ctx['series'],
        'number' => $ctx['number'],
        'emissionType' => EmissionType::from($ctx['emission_type']),
        'payload' => $payload,
        'issuedAt' => CarbonImmutable::parse($ctx['issued_at']),
    ];

    $context = $ctx['model'] === 58 ? new MdfeIssuanceContext(...$args) : new CteIssuanceContext(...$args);
    $built = (new $steps[$ctx['model']])->handle($context, fn ($c) => $c);

    file_put_contents("$golden/expected/$name.xml", $built->xml);
    echo "$name ok ".$built->accessKey->value."\n";
}
