Google APIs are usually provided by the https://github.com/google/google-api-objectivec-client-for-rest 
library for Objective-C, then linked into swift via a bridging header. However, there's oddly no
code for the Photos API in the officially library. 

Google provides a way to work around this: use the dicovery API to generate code for any API
that has a discovery document (see detail here: https://github.com/google/google-api-objectivec-client-for-rest/wiki/ServiceGenerator).
The Photos API does have a discovery document, and the code in this directory is the output of the service generator
run against that discovery document. 



