# Basic Boot Source Setup

This example shows how to create a multi-homed OpenShift cluster with `kcli` and then install KubeVirt.

1. Install `kcli`:
   [kcli install and OpenShift docs](https://kcli.readthedocs.io/en/latest/index.html#deploying-kubernetes-openshift-clusters-and-applications-on-top)
   don't forget https://kcli.readthedocs.io/en/latest/index.html#libvirt-additional-configuration
   
2. Get a pull secret and save it as `openshift-pull-secret.json`:
   [OpenShift pull secret](https://console.redhat.com/openshift/create/local)

3. Create a secondary network:

   ```bash
   kcli create network -c 192.168.20.0/24 secondary
   ```

4. Create the following YAML and save it as `parameters.yml`:

   ```yaml
   cluster: multi-homing
   domain: yourname.corp
   version: stable
   tag: 4.22
   ctlplanes: 3
   workers: 2
   memory: 24576
   numcpus: 20
   disk_size: 60
   kubetype: openshift
   network_type: OVNKubernetes
   pull_secret: openshift-qe-pull-secret.json
   extra_networks:
   - secondary
   cpu_partitioning: True
   ```

   Notes:
   - A special pull secret is needed for `nightly`. You can use `stable` instead, or obtain the required secret for nightly builds.

5. Create the cluster:

   ```bash
   kcli create cluster openshift --pf parameters.yml multi-homing
   ```

6. Install KubeVirt:

   ```bash
   kcli create app openshift kubevirt-hyperconverged
   ```

   Note:
   You can add the following to `parameters.yml` to include KubeVirt during cluster installation:

   ```yaml
   apps:
   - kubevirt-hyperconverged
   ```

Thanks Karim Boumedhel for this wonderful tool.

Once you have the cluster, you can run the scripts in the folders to adapt the cluster to `virt-cluster-validate` (WIP).

To get webUI (without sslip)
https://gist.github.com/oshoval/2c02cb9c75c1ca737b89803628903cb4
