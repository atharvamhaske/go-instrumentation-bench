# Live dev loop for one variant at a time on the local k3d cluster (`make cluster` first).
#   tilt up -- --variant goauto
# Tilt rebuilds and redeploys on every change under service/. Benchmarks still go through
# bench.sh: Tilt's file watching and rebuilds would add noise to the numbers.

config.define_string('variant', usage='baseline | manual | otelc | goauto')
variant = config.parse().get('variant', 'otelc')
if variant not in ['baseline', 'manual', 'otelc', 'goauto']:
    fail('unknown variant: ' + variant)

allow_k8s_contexts('k3d-bench')

docker_build(
    'bench/conduit',
    'service',
    build_args={'VARIANT': 'baseline' if variant == 'goauto' else variant},
    ignore=['*_test.go', '.otelc-build'],
)

k8s_yaml('k8s/infra.yaml')
if variant == 'goauto':
    k8s_yaml('k8s/app-goauto.yaml')
else:
    k8s_yaml(blob(str(read_file('k8s/app.yaml')).replace('__VARIANT__', variant)))

k8s_resource('jaeger', port_forwards=['16686:16686'], labels=['infra'])
k8s_resource('conduit', port_forwards=['8080:8080', '6060:6060'], resource_deps=['jaeger'], labels=['app'])

local_resource('go-test', cmd='make test', deps=['service'], labels=['checks'])
local_resource(
    'coverage',
    cmd='SKIP_DEPLOY=1 ./bench.sh coverage ' + variant,
    resource_deps=['conduit'],
    trigger_mode=TRIGGER_MODE_MANUAL,
    auto_init=False,
    labels=['checks'],
)
