# Dune-Awakening
Dune Awakening scripts I've made

## Script to add a Hagga Basin

## Prerequists:
1: You myst have python3 and py3-yaml installed on the server, they can be installed on alpine like:

apk add python3 py3-yaml

2: You need to know the namespace of the pods running your server, you can get that with:

kubectl get pods -A

The namespace will start with "funcom-seabass-sh-"

## Add an additional Hagga Basin:
namespace = Your namespace

command = add or delete

ID = ID greater than 28

## usage
./survival1.sh namespace command ID

## example, to add a Hagga Basin
./survival1.sh funcom-seabass-sh-xxxxx-yyyy add 3

## example, to delete a Hagga Basin
./survival1.sh funcom-seabass-sh-xxxxx-yyyy delete 3

