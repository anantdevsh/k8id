local addMixin = import 'lib/addmixin.libsonnet';
local utils = import 'lib/utils.libsonnet';

local remove_nulls = (
  function(arr)
    std.filter((function(o) o != null), arr)
);

local ext_vars = std.extVar('vars');

local default_vars = {
  prometheus_scrape_namespaces+: [],
  prometheus_scrape_default_namespaces+: [
    'argocd',
    'system',
    'cert-manager',
  ],

  prometheus_operator_resources: {
    limits: { memory: '80Mi' },
    requests: { cpu: '20m', memory: '80Mi' },
  },
  prometheus_operator_kubeRbacProxyMain_resources: {
    limits: { memory: '40Mi' },
    requests: { cpu: '40m', memory: '40Mi' },
  },
  alertmanager_resources: {
    limits: { memory: '50Mi' },
    requests: { cpu: '20m', memory: '50Mi' },
  },
  prometheus_resources: {
    limits: { memory: '3Gi' },
    requests: { cpu: '500m', memory: '1500Mi' },
  },
  grafana_resources: {
    limits: { memory: '200Mi' },
    requests: { cpu: '100m', memory: '100Mi' },
  },
  node_exporter_resources: {
    limits: { memory: '180Mi' },
    requests: { cpu: '500m', memory: '180Mi' },
  },
  node_exporter_kubeRbacProxyMain_resources: {
    limits: { memory: '40Mi' },
    requests: { cpu: '40m', memory: '40Mi' },
  },
  kube_state_metrics_kubeRbacProxyMain_resources: {
    limits: { memory: '40Mi' },
    requests: { cpu: '20m', memory: '40Mi' },
  },
  kube_state_metrics_kubeRbacProxySelf_resources: {
    limits: { memory: '40Mi' },
    requests: { cpu: '20m', memory: '40Mi' },
  },

  grafana_keycloak_enable: false,
  grafana_keycloak_secretref: {
    name: 'kube-prometheus-stack-grafana',
    key: 'grafana-keycloak-secret',
  },
  prometheus: {
    storage: {
      size: '10Gi',
      classname: 'rook-ceph-block',
    },
    retention: '30d',
  },
  grafana_ingress_annotations: {
    'cert-manager.io/cluster-issuer': 'letsencrypt',
  },
  addMixins: {
    ceph: true,
    sealedsecrets: true,
    etcd: true,
    velero: false,
    'cert-manager': true,
    'kubernetes-version-info': true,
  },
  mixin_configs: {
    // Example:
    //
    // velero+: {
    //   selector: 'schedule=~"^ops.+"',
    // },
  },
};

local vars = std.mergePatch(default_vars, ext_vars);

local mixins = remove_nulls([
  addMixin(
    'ceph',
    (import 'github.com/ceph/ceph-mixins/mixin.libsonnet'),
    vars,
  ),
  addMixin(
    'sealedsecrets',
    (import 'github.com/bitnami-labs/sealed-secrets/contrib/prometheus-mixin/mixin.libsonnet'),
    vars,
  ),
  addMixin(
    'etcd',
    (import 'github.com/etcd-io/etcd/contrib/mixin/mixin.libsonnet'),
    vars,
  ),
  addMixin(
    'velero',
    (import 'mixins/velero/mixin.libsonnet'),
    vars,
  ),
  addMixin(
    'kubernetes-version-info',
    (import 'mixins/kube-version/mixin.libsonnet'),
    vars,
  ),
  addMixin(
    'cert-manager',
    (import 'gitlab.com/uneeq-oss/cert-manager-mixin/mixin.libsonnet'),
    vars,
  ),
]);

local scrape_namespaces = std.uniq(std.sort(std.flattenArrays(
  [
    vars.prometheus_scrape_namespaces,
    vars.prometheus_scrape_default_namespaces,
  ] + (
    if std.objectHas(vars, 'connect_obmondo') && vars.connect_obmondo then
      [
        ['obmondo'],
      ]
    else []
  )
)));

local relabelings = import 'kube-prometheus/addons/dropping-deprecated-metrics-relabelings.libsonnet';

local kp =
  (import 'kube-prometheus/main.libsonnet') +
  // Uncomment the following imports to enable its patches
  // (import 'kube-prometheus/addons/anti-affinity.libsonnet') +
  // (import 'kube-prometheus/addons/managed-cluster.libsonnet') +
  // (import 'kube-prometheus/addons/node-ports.libsonnet') +
  // (import 'kube-prometheus/addons/static-etcd.libsonnet') +
  // (import 'kube-prometheus/addons/custom-metrics.libsonnet') +
  // (import 'kube-prometheus/addons/external-metrics.libsonnet') +

  {
    grafana+: {
      networkPolicy+: {
        spec+: {
          ingress+: [{
            from: [{
              podSelector: {
                matchLabels: {
                  'app.kubernetes.io/name': 'traefik',
                },
              },
              namespaceSelector: {
                matchLabels: {
                  'kubernetes.io/metadata.name': 'traefik',
                },
              },
            }],
            ports: [{
              port: 'http',
              protocol: 'TCP',
            }],
          }],
        },
      },
    },
  } +
  {
    prometheus+: {
      prometheus+: {
        spec+: {
          replicas: 1,
          resources: vars.prometheus_resources,
          retention: vars.prometheus.retention,
          storage: {
            volumeClaimTemplate: {
              apiVersion: 'v1',
              kind: 'PersistentVolumeClaim',
              spec: {
                accessModes: ['ReadWriteOnce'],
                resources: { requests: { storage: vars.prometheus.storage.size } },
                storageClassName: vars.prometheus.storage.classname,
              },
            },
          },
        },
      },
      networkPolicy+: {
        spec+: {
          ingress+: [
            {
              from: [{
                podSelector: {
                  matchLabels: {
                    'app.kubernetes.io/name': 'prometheus-adapter',
                  },
                },
              }],
              ports: [{
                port: 9090,
                protocol: 'TCP',
              }],
            },
            {
              from: [{
                namespaceSelector: {
                  matchLabels: {
                    'kubernetes.io/metadata.name': 'obmondo',
                  },
                },
                podSelector: {
                  matchLabels: {
                    'app.kubernetes.io/name': 'obmondo-k8s-agent',
                  },
                },
              }],
              ports: [{
                port: 9090,
                protocol: 'TCP',
              }],
            },
          ],
        },
      },
    },
  } + (
    if vars.platform == 'kubeadm' then {
      kubernetesControlPlane+: {
        serviceMonitorKubeScheduler+: {
          spec+: {
            endpoints: [{
              port: 'https-metrics',
              interval: '30s',
              scheme: 'http',
              bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
              tlsConfig: { insecureSkipVerify: true },
            }],
          },
        },
        serviceMonitorKubeControllerManager+: {
          spec+: {
            endpoints: [{
              port: 'https-metrics',
              interval: '30s',
              scheme: 'http',
              bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
              tlsConfig: {
                insecureSkipVerify: true,
              },
              metricRelabelings: relabelings + [
                {
                  sourceLabels: ['__name__'],
                  regex: 'etcd_(debugging|disk|request|server).*',
                  action: 'drop',
                },
              ],
            }],
            selector: {
              matchLabels: { 'app.kubernetes.io/name': 'kube-controller-manager' },
            },
            namespaceSelector: {
              matchNames: ['kube-system'],
            },
          },
        },
      },
    } else {}
  ) +
  {
    values+:: {
      common+: {
        platform: vars.platform,
        namespace: 'monitoring',
      },

      prometheus+: {
        // [ i for i in scrape_namespaces if std.get(defaults.mixins, i) == true ],
        namespaces+: scrape_namespaces,
      },

      prometheusOperator+: {
        resources: vars.prometheus_operator_resources,
        kubeRbacProxyMain+: {
          resources+: vars.prometheus_operator_kubeRbacProxyMain_resources,
        },
      },
      // This is ONLY supported in release-0.11+ and main
      kubeStateMetrics+: {
        kubeRbacProxyMain+: {
          resources+: vars.kube_state_metrics_kubeRbacProxyMain_resources,
        },
        kubeRbacProxySelf+: {
          resources+: vars.kube_state_metrics_kubeRbacProxySelf_resources,
        },
      },

      nodeExporter+: {
        resources: vars.node_exporter_resources,
        kubeRbacProxyMain+: {
          resources+: vars.node_exporter_kubeRbacProxyMain_resources,
        },
      },

      grafana+: {
        resources: vars.grafana_resources,
        analytics+: {
          check_for_updates: false,
        },
        env: if vars.grafana_keycloak_enable then [
          {
            name: 'GF_SECURITY_DISABLE_INITIAL_ADMIN_CREATION',
            value: 'true',
          },
          {
            name: 'GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET',
            valueFrom+: {
              secretKeyRef+: {
                name: vars.grafana_keycloak_secretref.name,
                key: vars.grafana_keycloak_secretref.key,
              },
            },
          },
        ] else [],
        config+: {
          sections: {
            date_formats: { default_timezone: 'UTC' },
            auth: {
              disable_login_form: false,
              // oauth_auto_login: true,
              disable_signout_menu: false,
            } + (
              if vars.grafana_keycloak_enable then {
                signout_redirect_url: vars.grafana_signout_redirect_url,
              } else {}
            ),
            analytics: {
              check_for_updates: false,
            },
            server: {
              root_url: vars.grafana_root_url,
            },
          } + (
            if vars.grafana_keycloak_enable then
              {
                'auth.generic_oauth': {
                  enabled: true,
                  allow_sign_up: true,
                  scopes: 'openid profile email',
                  name: 'Keycloak',
                  auth_url: vars.grafana_auth_url,
                  token_url: vars.grafana_token_url,
                  api_url: vars.grafana_api_url,
                  client_id: 'grafana',
                  role_attribute_path: "contains(not_null(roles[*],''), 'Admin') && 'Admin' || contains(not_null(roles[*],''), 'Editor') && 'Editor' || contains(not_null(roles[*],''), 'Viewer') && 'Viewer'|| ''",

                },
              }
            else {}
          ),
        },
      },
    },
    alertmanager+: {
      alertmanager+: {
        spec+: {
          replicas: 1,
          resources: vars.alertmanager_resources,
          secrets: (
            if std.objectHas(vars, 'connect_obmondo') && vars.connect_obmondo then [
              'obmondo-clientcert',
              'alertmanager-main',
            ] else []
          ),
        },
      },
    } + (
      if std.objectHas(vars, 'connect_obmondo') && vars.connect_obmondo then {
        secret:: {},
      } else {}
    ),
  } + (
    if std.objectHas(vars, 'grafana_ingress_host') then
      {
        ingress+:: {
          grafana: utils.ingress(
            'grafana',
            $.values.common.namespace,
            [{
              host: vars.grafana_ingress_host,
              http: {
                paths: [{
                  path: '/',
                  pathType: 'Prefix',
                  backend: {
                    service: {
                      name: 'grafana',
                      port: {
                        name: 'http',
                      },
                    },
                  },
                }],
              },
            }],
            [{
              secretName: 'kube-prometheus-grafana-tls',
              hosts: [
                vars.grafana_ingress_host,
              ],
            }],
            vars.grafana_ingress_annotations,
          ),
        },
      } else {}
  );


{
  'setup/0namespace-namespace': kp.kubePrometheus.namespace +
                                ({
                                   metadata+: {
                                     labels:
                                       { monitoring: 'kube-prometheus-stack' },
                                   },
                                 }),
} +
{
  ['setup/prometheus-operator-' + name]: kp.prometheusOperator[name]
  for name in std.filter((function(name) name != 'serviceMonitor' && name != 'prometheusRule'), std.objectFields(kp.prometheusOperator))
} +
// serviceMonitor and prometheusRule are separated so that they can be created after the CRDs are ready
{ 'prometheus-operator-serviceMonitor': kp.prometheusOperator.serviceMonitor } +
{ 'prometheus-operator-prometheusRule': kp.prometheusOperator.prometheusRule } +
{ 'kube-prometheus-prometheusRule': kp.kubePrometheus.prometheusRule } +
{ ['alertmanager-' + name]: kp.alertmanager[name] for name in std.objectFields(kp.alertmanager) } +
(if vars['blackbox-exporter'] then { ['blackbox-exporter-' + name]: kp.blackboxExporter[name] for name in std.objectFields(kp.blackboxExporter) } else {}) +
{ ['grafana-' + name]: kp.grafana[name] for name in std.objectFields(kp.grafana) } +
{ ['kube-state-metrics-' + name]: kp.kubeStateMetrics[name] for name in std.objectFields(kp.kubeStateMetrics) } +
{ ['kubernetes-' + name]: kp.kubernetesControlPlane[name] for name in std.objectFields(kp.kubernetesControlPlane) } +
// Ordering matters! This next absurd object **has** to come after the inclusion
// of `kubernetesControlPlane` above -- otherwise we'll overwrite the object and
// remove our filtering.
{ 'kubernetes-prometheusRule': kp.kubernetesControlPlane.prometheusRule {
  spec+: {
    groups: std.filter((
              function(o)
                std.objectHas(o, 'rules') && o.name != 'kubernetes-system-apiserver'
            ), kp.kubernetesControlPlane.prometheusRule.spec.groups)
            +
            [{
              name: 'kubernetes-system-apiserver',
              rules:
                std.filter(
                  (
                    function(o)
                      std.objectHas(o, 'alert') &&
                      o.alert != 'KubeClientCertificateExpiration'
                  ),
                  std.filter((
                    function(o)
                      std.objectHas(o, 'rules') && o.name == 'kubernetes-system-apiserver'
                  ), kp.kubernetesControlPlane.prometheusRule.spec.groups)[0].rules
                ),
            }],
  },
} } +
{ ['node-exporter-' + name]: kp.nodeExporter[name] for name in std.objectFields(kp.nodeExporter) } +
{ ['prometheus-' + name]: kp.prometheus[name] for name in std.objectFields(kp.prometheus) } +
(
  // Need to figure out elseif
  // if vars != 'gke' || vars != 'azure' didnt worked
  if vars.platform != 'gke' then {
    ['prometheus-adapter-' + name]: kp.prometheusAdapter[name]
    for name in std.objectFields(kp.prometheusAdapter)
  } else {}
) +
(if std.objectHas(vars, 'grafana_ingress_host') then { [name + '-ingress']: kp.ingress[name] for name in std.objectFields(kp.ingress) } else {})
// Rendering prometheusRules object. This is an object compatible with prometheus-operator CRD definition for prometheusRule
+ { [o._config.name + '-prometheus-rules']: o.prometheusRules for o in std.filter((function(o) o.prometheusRules != null), mixins) }
