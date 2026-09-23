<?php

$config = array(
    'admin' => array(
        'core:AdminPassword',
    ),

    'default-sp' => array(
        'saml:SP',
        'entityID' => 'https://poc.example.com/simplesaml/module.php/saml/sp/metadata.php/default-sp',
        'idp' => 'https://poc.example.com/am',
        'discoURL' => null,
        'NameIDFormat' => 'urn:oasis:names:tc:SAML:2.0:nameid-format:transient',
    ),

);
