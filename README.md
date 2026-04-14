# Hitachi CSI on OpenShift: A Field Guide

A practical, field-tested guide for deploying and operating Hitachi Storage Plugin for Containers (HSPC) on Red Hat OpenShift clusters running on bare-metal with Fibre Channel storage.

This guide covers the full lifecycle: storage preparation, multipath configuration, CSI operator installation, StorageClass setup, LUN tuning, validation, and troubleshooting. It comes from real production and lab deployments, not just vendor documentation.

## Who is this for?

Platform engineers and storage administrators working with:
- Red Hat OpenShift 4.x on bare-metal
- Hitachi VSP storage arrays (VSP 5000 series, VSP E series, VSP One Block, etc.)
- Fibre Channel connectivity (iSCSI is mentioned where applicable)
- HyperShift hosted clusters or traditional standalone/IPI clusters

## Contents

| Section | What it covers |
|---------|---------------|
| [Storage Preparation](docs/01-storage-preparation.md) | Pool planning, LDEV allocation, service accounts, resource groups |
| [Multipath Configuration](docs/02-multipath.md) | multipathd setup, Hitachi device tuning, path limits |
| [CSI Operator Installation](docs/03-csi-installation.md) | OLM subscription, version pinning, HSPC custom resource |
| [StorageClass and Secrets](docs/04-storageclass.md) | Secret structure, StorageClass parameters, multi-array setups |
| [Snapshots](docs/05-snapshots.md) | VolumeSnapshotClass configuration |
| [LUN Boost](docs/06-lun-boost.md) | Increasing max LUN count via MachineConfig |
| [Validation](docs/07-validation.md) | PVC functional tests, FC diagnostics |
| [HyperShift Hosted Clusters](docs/08-hypershift.md) | ConfigMap + NodePool pattern for hosted clusters |
| [Troubleshooting](docs/09-troubleshooting.md) | Common errors and how to fix them |
| [Examples](examples/) | Complete configuration examples |

## Quick reference

```bash
# Check CSI pods
oc get pods -n storage-hitachi

# Check StorageClasses
oc get sc | grep hitachi

# Check available operator versions
oc get packagemanifest hspc-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}: {.currentCSV}{"\n"}{end}'

# Verify multipath on a node
oc debug node/<node> -- chroot /host multipath -ll

# Verify LUN boost on a node
oc debug node/<node> -- chroot /host cat /sys/module/scsi_mod/parameters/max_luns
```

## License

This project is licensed under the [Apache License 2.0](LICENSE).
