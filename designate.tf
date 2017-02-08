# Keypair
resource "openstack_compute_keypair_v2" "designate" {
    name = "designate"
    public_key = "${file("files/key/designate.pub")}"
}

resource "openstack_compute_instance_v2" "designate-standalone" {
  name = "designate-standalone"
  image_name = "Ubuntu 14.04"
  flavor_name = "m1.medium"
  key_pair = "designate"
  security_groups = ["default"]
}

resource "null_resource" "designate-standalone" {
  connection {
    user = "ubuntu"
    private_key = "${file("files/key/designate")}"
    host = "${openstack_compute_instance_v2.designate-standalone.access_ip_v6}"
  }
  provisioner file {
    source = "files"
    destination = "files"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo bash /home/ubuntu/files/bootstrap.sh"
    ]
  }
}
