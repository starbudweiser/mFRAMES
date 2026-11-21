# mframes-relay

Point de rencontre et relais aveugle de mFRAMES, à héberger soi-même (NAS, VPS, Docker). Il relaie des trames **chiffrées de bout en bout** : il ne voit ni média, ni texte, ni clé, ne stocke rien et ne journalise rien.

```bash
python3 mframes-relay.py --port 7766          # directement
docker build -t mframes-relay . && docker run -d -p 7766:7766 --restart unless-stopped mframes-relay
```

Dans mFRAMES : Réglages › Réseau › Point de rencontre : `votre-serveur:7766`. Ouvrir le port 7766 (TCP) vers le serveur. Le lien d'invitation contient l'adresse du relais : le client n'a rien à régler.
