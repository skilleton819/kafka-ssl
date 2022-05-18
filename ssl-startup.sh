#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

KAFKA_SSL_KEYSTORE_FILENAME=kafka.server.keystore.jks
KAFKA_SSL_TRUSTSTORE_FILENAME=kafka.server.truststore.jks
# write pwds to file from environment
echo ${CA_SERVER_PASSWORD} >> capwd


# get root CA certificate with exact fingerprint
echo "<<< GET CA CERT"
step ca root ca.crt --ca-url ${CA_SERVER_ENDPOINT} --fingerprint ${CA_CERTIFICATE_FINGERPRINT}

# get one-time token to generate certificate by CA and sign it
echo "<<< GET OTT"
ACCESS_TOKEN=$(step ca token ${HOST_ENDPOINT} --ca-url ${CA_SERVER_ENDPOINT} --root ca.crt --provisioner-password-file capwd)
rm capwd

# get specific hostname certificates, using one time token
# --not-after :in hours shown certificate validity (1 year by default. 1 day minimum)
# --kty :choose type of encryption for private key generation (ECDSA, EdDSA, and RSA allowed)
# --length :length of private key (forced 4096)
echo "<<< GET HOST CERTS"
step ca certificate --ca-url ${CA_SERVER_ENDPOINT} ${HOST_ENDPOINT} ${HOST_ENDPOINT}.crt ${HOST_ENDPOINT}.key --token ${ACCESS_TOKEN} --not-after 8760h --kty RSA --size 4096

# insert into pcs12 store private key for specified endpoint
echo "<<< INSERT HOST CERTS"
openssl pkcs12 -export -in ${HOST_ENDPOINT}.crt -inkey ${HOST_ENDPOINT}.key -name ${HOST_ENDPOINT} -password pass:${KAFKA_SSL_KEYSTORE_PASSWORD} > server.p12

# import server keys into jks store
# -storepass :password for keystore
# -srcstorepass :password for original (pcs12) storage
# -noprompt :key to skip step "do you trust this certificate?"
# -destkeystore :name of .jks store for kafka
# -alias :hostname (alias) for listenter
echo "<<< GENERATE KEYSTORE"
keytool -importkeystore -storepass ${KAFKA_SSL_KEYSTORE_PASSWORD} -srcstorepass ${KAFKA_SSL_KEYSTORE_PASSWORD} -noprompt -srckeystore server.p12 -destkeystore ${KAFKA_SSL_KEYSTORE_FILENAME} -srcstoretype pkcs12 -alias ${HOST_ENDPOINT}

# import CA cert into truststore (CA's, that are welcomed to sign client certs)
# -noprompt :key to skip step "do you trust this certificate?"
# -storepass :password for truststore
echo "<<< GENERATE TRUSTSTORE"
keytool -keystore ${KAFKA_SSL_TRUSTSTORE_FILENAME} -alias CARoot -import -file ca.crt -storepass ${KAFKA_SSL_TRUSTSTORE_PASSWORD} -noprompt

# step to copy all required files (credentials and stores) into specific location for kafka
mv ${KAFKA_SSL_KEYSTORE_FILENAME} ${KAFKA_SSL_KEYSTORE_LOCATION}
mv ${KAFKA_SSL_TRUSTSTORE_FILENAME} ${KAFKA_SSL_TRUSTSTORE_LOCATION}
#echo ${KAFKA_SSL_TRUSTSTORE_PASSWORD} >> /etc/kafka/secrets/${KAFKA_SSL_KEY_CREDENTIALS}
echo ${KAFKA_SSL_KEYSTORE_PASSWORD} >>  /etc/kafka/secrets/${KAFKA_SSL_KEYSTORE_CREDENTIALS}
echo ${KAFKA_SSL_TRUSTSTORE_PASSWORD} >>  /etc/kafka/secrets/${KAFKA_SSL_TRUSTSTORE_CREDENTIALS}
# remove files that are no more needed
rm ca.crt ${HOST_ENDPOINT}.crt ${HOST_ENDPOINT}.key server.p12

# start command for kafka 5.3.0 May be different for another versions
bash /etc/confluent/docker/run
