# Docker Pulsar PHP 8.6

Image PHP 8.6 (Apache, Bookworm) nécessaire pour les projets Pulsar, jumelle de `docker-pulsar-php84`. Elle est basée
sur `php:8.6.0RC7-apache-bookworm` : c'est une version candidate (RC7) jusqu'à la sortie de PHP 8.6.0, prévue le
2026-11-19. À cette date, il faudra remplacer la ligne `FROM` par `php:8.6.0-apache-bookworm`.

## Définitions

* PHP 8.6.0RC7 (Apache-Bookworm, ZTS comme l'image officielle 8.6)
* Composer
* XDebug (installé mais désactivé)
* SSH2
* MailCatcher
* Extensions PHP
  * pdo_pgsql, pgsql, pdo_sqlite, sqlite3
  * curl, zip, intl, xml, dom, simplexml, xmlreader, xmlwriter, mbstring, exif, gettext, gmp, sodium, iconv, openssl
  * APCu
  * GD (avec freetype et jpeg)
  * OPcache
  * `lexbor` et `uri` sont nouvelles : PHP 8.6 les expose comme extensions
* Modules Apache : rewrite, headers, expires, ssl

La dernière étape de la construction échoue si une extension chargée par l'image 8.4 ne l'est pas ici, ou si XDebug
ne se charge pas une fois activé.

## Extensions compilées depuis les sources

Les images officielles PHP 8.6 n'ont pas `pecl` : chaque extension PECL est compilée depuis ses sources, avec une
version ou un _commit_ fixe.

* **APCu** : _commit_ `fb2c942552a3f5dab7f4dea4afb5cf0831222c57` de `krakjoe/apcu` (`5.1.29-dev`). La dernière version
  PECL (5.1.28) ne compile pas sur PHP 8.6.
* **XDebug** : _commit_ `85f513aca01e2edb9b854b6c1bb0f550e62f887b` de `xdebug/xdebug` (`3.6.0alpha2-dev`). La dernière
  version refuse PHP 8.6 à la configuration.
* **SSH2** : version PECL 1.3.1 (même version que l'image 8.4), téléchargée en archive. Les versions plus récentes
  demandent libssh2 1.11 ou plus, alors que Bookworm fournit 1.10.

Ces deux _commits_ sont à remplacer par une version PECL dès qu'elle compile sur PHP 8.6.

## Configuration Apache

* `AllowEncodedSlashes NoDecode` dans chaque `<VirtualHost>` activé : un `%2F` dans un chemin se rend à PHP au lieu de
  recevoir la page 404 d'Apache. La construction échoue si un _vhost_ en est dépourvu; un _vhost_ ajouté par une image
  dérivée doit porter la directive lui-même.
* `ServerTokens Prod` et `ServerSignature Off` : l'en-tête `Server` vaut simplement `Apache`.

## Directives personnalisées pour PHP.ini

```ini
apc.enable_cli = 1

[xdebug]
xdebug.output_dir='/xdebug.d'
xdebug.mode = profile
xdebug.use_compression = true
```

## Publication

* Un _push_ sur `main` publie `ghcr.io/ophelios-studio/docker-pulsar-php86:latest`.
* Une _pull request_ vers `main` publie `ghcr.io/ophelios-studio/docker-pulsar-php86-test:latest`.
* Les deux workflows peuvent aussi être lancés à la main (`workflow_dispatch`). Les images sont construites en amd64 et
  en arm64.

## Utilisation

Dans une application, la seule ligne à changer :

```dockerfile
FROM ghcr.io/ophelios-studio/docker-pulsar-php86:latest
```
