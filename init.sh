#!/bin/bash
# This script runs automatically on the VM's FIRST BOOT via cloud-init.
# It installs Apache web server so the VM starts serving HTTP traffic immediately.
sudo apt-get update
sudo apt-get install -y apache2
