---
sidebar_position: 1
---

# Preparing the servers

You will need to prepare your servers for the installation of k3s.

## Assign static IPs

For the cluster to work properly, you need to assign static IPs to the servers. You can do so on your router settings.

## Disable Swap

Swap must be disabled on all servers. Edit the `/etc/fstab` and comment out the line that contains swap image. It should look like this:

```
/swap.img      none    swap    sw      0       0
```

Then reboot the server.

## Copy your SSH key

If you haven't yet created an SSH key, you can do so with the following command:

```bash
ssh-keygen -t ed25519 -C "your_email@example.com"
```

You can then copy it to the servers using `ssh-copy-id`:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub lorenzo@<host ip>
```

`lorenzo` is the username I use to connect to the servers. You can replace it with your own username.

## Enable `sudo` without password

Because `k3sup` uses SSH with `sudo`, you need to allow running `sudo` without a password. To do this, open the `sudoers` file with:

```bash
sudo visudo
```

and add this line at the end of the file:

```bash
lorenzo ALL=(ALL) NOPASSWD:ALL
```

