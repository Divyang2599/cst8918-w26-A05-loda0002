# ============================================================
# LAB-A05 Terraform Web Server on Azure
# Student: loda0002 (Divyang)
# Course:  CST8918 - DevOps: Infrastructure as Code
# ============================================================

# ── STEP 1: Tell Terraform which version + providers we need ──────────────────
# Think of this like a package.json in Node — it lists your dependencies.
terraform {
  required_version = ">= 1.1.0"

  required_providers {
    # azurerm  = the plugin that knows how to talk to Azure
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0.2"
    }
    # cloudinit = lets us run a shell script on VM first boot
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "2.3.3"
    }
  }
}

# ── STEP 2: Configure the providers ──────────────────────────────────────────
provider "azurerm" {
  # Empty features block = use Azure defaults. Required but can be blank.
  features {}
}

provider "cloudinit" {
  # No extra config needed
}

# ── STEP 3: Variables (reusable inputs) ───────────────────────────────────────
# Variables are like function parameters — you pass values in at runtime.
# This avoids hardcoding names everywhere.

variable "labelPrefix" {
  description = "Your college username. Forms the start of every resource name."
  type        = string
  # No default → Terraform will ask you for it when you run apply
}

variable "region" {
  description = "Azure region where all resources are deployed."
  type        = string
  default     = "canadacentral"
}

variable "admin_username" {
  description = "The admin login name for the Ubuntu VM."
  type        = string
  default     = "azureadmin"
}

# ── STEP 4: Resource Group ────────────────────────────────────────────────────
# A Resource Group is a logical folder in Azure. Everything related to this
# project lives inside it. Easy to delete everything at once later.
resource "azurerm_resource_group" "rg" {
  name     = "${var.labelPrefix}-A05-RG"   # e.g. loda0002-A05-RG
  location = var.region
}

# ── STEP 5: Public IP Address ─────────────────────────────────────────────────
# This is the IP the internet uses to reach your VM.
# Dynamic = Azure assigns it when the VM starts (free tier, may change on restart).
resource "azurerm_public_ip" "webserver_ip" {
  name                = "${var.labelPrefix}-A05-PublicIP"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Dynamic"
}

# ── STEP 6: Virtual Network (VNet) ────────────────────────────────────────────
# A VNet is a private network inside Azure — like a virtual office LAN.
# 10.0.0.0/16 means we have 65,536 possible private IP addresses in this network.
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.labelPrefix}-A05-VNet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

# ── STEP 7: Subnet ────────────────────────────────────────────────────────────
# A subnet is a segment of the VNet. Like splitting an office floor into rooms.
# 10.0.1.0/24 = 256 addresses within the VNet for this subnet.
resource "azurerm_subnet" "subnet" {
  name                 = "${var.labelPrefix}-A05-Subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# ── STEP 8: Network Security Group (NSG) ─────────────────────────────────────
# An NSG is a firewall. It controls what traffic is allowed IN and OUT.
# Without this, no traffic reaches your VM even if it has a public IP.
resource "azurerm_network_security_group" "nsg" {
  name                = "${var.labelPrefix}-A05-NSG"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # Rule 1: Allow SSH on port 22 (so you can log into the VM remotely)
  security_rule {
    name                       = "SSH"
    priority                   = 1001          # lower number = higher priority
    direction                  = "Inbound"     # traffic coming IN
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"           # any source port
    destination_port_range     = "22"          # SSH port
    source_address_prefix      = "*"           # from anywhere
    destination_address_prefix = "*"
  }

  # Rule 2: Allow HTTP on port 80 (so browsers can reach Apache)
  security_rule {
    name                       = "HTTP"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"          # HTTP port
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# ── STEP 9: Network Interface Card (NIC) ─────────────────────────────────────
# A NIC connects the VM to the network — like a network card in a physical computer.
# It gets both a private IP (inside VNet) and the public IP (from the internet).
resource "azurerm_network_interface" "nic" {
  name                = "${var.labelPrefix}-A05-NIC"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.webserver_ip.id  # link public IP
  }
}

# ── STEP 10: Attach NSG to the NIC ───────────────────────────────────────────
# We apply the firewall rules to the NIC (not the whole subnet) because these
# rules are specific to the web server VM only.
resource "azurerm_network_interface_security_group_association" "nsg_assoc" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# ── STEP 11: Cloud-init startup script ───────────────────────────────────────
# cloudinit_config wraps your init.sh and passes it to the VM.
# The VM runs this script automatically on FIRST BOOT — installs Apache.
data "cloudinit_config" "init" {
  gzip          = false
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content      = file("${path.module}/init.sh")  # reads your init.sh file
  }
}

# ── STEP 12: The Virtual Machine ─────────────────────────────────────────────
# This is the actual Ubuntu server. All previous resources lead to this one.
# Notice how it references nic, resource group, cloud-init — Terraform figures
# out the correct ORDER to create everything automatically.
resource "azurerm_linux_virtual_machine" "webserver" {
  name                = "${var.labelPrefix}-A05-VM"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  size                = "Standard_B1s"          # cheapest VM for testing
  admin_username      = var.admin_username

  # Connect NIC to the VM
  network_interface_ids = [
    azurerm_network_interface.nic.id
  ]

  # SSH key authentication (more secure than passwords)
  admin_ssh_key {
    username   = var.admin_username
    public_key = file("~/.ssh/id_rsa.pub")      # your public key from your laptop
  }

  # OS disk settings
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"       # standard magnetic disk (cheap)
  }

  # Ubuntu 22.04 LTS — "Jammy Jellyfish" — latest stable supported version
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # Pass the init.sh script to run on first boot
  custom_data = data.cloudinit_config.init.rendered
}

# ── STEP 13: Outputs ──────────────────────────────────────────────────────────
# Outputs print useful info after terraform apply finishes.
# Like return values from a function.

output "resource_group_name" {
  description = "Name of the Azure Resource Group"
  value       = azurerm_resource_group.rg.name
}

output "public_ip_address" {
  description = "Public IP to access the web server and SSH"
  value       = azurerm_linux_virtual_machine.webserver.public_ip_address
}
