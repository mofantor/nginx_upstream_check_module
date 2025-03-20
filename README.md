## nginx_http_upstream_check_module 
support upstream health check with Nginx

## example
```nginx
    http {

        upstream cluster {

            # simple round-robin
            server 192.168.0.1:80;
            server 192.168.0.2:80;

            check interval=5000 rise=1 fall=3 timeout=4000;

            #check interval=3000 rise=2 fall=5 timeout=1000 type=ssl_hello;

            #check interval=3000 rise=2 fall=5 timeout=1000 type=http;
            #check_http_send "HEAD / HTTP/1.0\r\n\r\n";
            #check_http_expect_alive http_2xx http_3xx;
        }

        server {
            listen 80;

            location / {
                proxy_pass http://cluster;
            }

            location /status {
                check_status;

                access_log   off;
                allow SOME.IP.ADD.RESS;
                deny all;
           }
        }

    }
```

### Description
Add the support of health check with the upstream servers.

## Directives
### check
+ syntax
> check interval=milliseconds [fall=count] [rise=count] [timeout=milliseconds] [default_down=true|false] [type=tcp|http|ssl_hello|mysql|ajp|fastcgi]

+ default: 
> *none, if parameters omitted, default parameters are interval=30000 fall=5 rise=2 timeout=1000 default_down=true type=tcp*

+ context: **upstream**

+ description: Add the health check for the upstream servers.

+ parameters

| Parameter | 	Description |
| -------- | --------------- |
| interval | the check request's interval time(ms). |
| fall | After fall_count check failures, the server is marked down. |
| rise | After rise_count check success, the server is marked up |
| timeout | Check request timeout (ms). |
| default_down | Initial server state (true = down, false = up). |
| type | Check protocol type (see below). |
| port | Custom check port (default: same as backend server). |


+ Supported type values

    ​**tcp**: Simple TCP socket connection check.

    ​**ssl_hello**: Send SSL ClientHello and receive ServerHello.

    ​**http**: Send HTTP request and validate response.

    ​**mysql**: Check MySQL server greeting.

    ​**ajp**: Send AJP Cping and validate Cpong response.

    ​**fastcgi**: Validate FastCGI response.


### check_http_send
+ ​Syntax： 
> check_http_send http_packet

+ ​Default:
> "GET / HTTP/1.0\r\n\r\n"

​Context:
> upstream

​Description:
> Defines the HTTP request sent for health checks (when type=http).

### check_http_expect_alive
+ ​Syntax
> check_http_expect_alive [http_2xx | http_3xx | http_4xx | http_5xx]

+ ​Default
> http_2xx http_3xx

+ ​Context:
> upstream

+ ​Description:
> HTTP status codes indicating a healthy server.


### check_keepalive_requests
+ ​Syntax:
> check_keepalive_requests num

+ ​Default:
> 1

+ ​Context:
> upstream

+ ​Description:
> Number of requests sent per keepalive connection.

### check_fastcgi_param
+ ​Syntax:
> check_fastcgi_params parameter value

+ Default
```nginx
check_fastcgi_param "REQUEST_METHOD" "GET";
check_fastcgi_param "REQUEST_URI" "/";
check_fastcgi_param "SCRIPT_FILENAME" "index.php";
```

+ Context
> upstream

+ Description
> FastCGI headers sent for health checks (when type=fastcgi).

### check_shm_size
+ ​Syntax:
> check_shm_size size

+ ​Default:
> 1M

+ ​Context:
> http

+ ​Description:
> Shared memory size for storing health check data.

### check_status
+ ​Syntax:
> check_status [html | csv | json]

+ ​Default:
> html

+ ​Context:
> location

+ ​Description:
Displays upstream server status. Use URL parameters to customize output

+ ​URL parameters:
    + ?format=html|csv|json
    + ?status=up|down

Below it's the sample html page: 
```http://IP:PORT/status?format=html```
```html
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN
"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<title>Nginx http upstream check status</title>
    <h1>Nginx http upstream check status</h1>
    <h2>Check upstream server number: 1, generation: 3</h2>
            <th>Index</th>
            <th>Upstream</th>
            <th>Name</th>
            <th>Status</th>
            <th>Rise counts</th>
            <th>Fall counts</th>
            <th>Check type</th>
            <th>Check port</th>
            <td>0</td>
            <td>backend</td>
            <td>106.187.48.116:80</td>
            <td>up</td>
            <td>39</td>
            <td>0</td>
            <td>http</td>
            <td>80</td>
            .....
```
Below it's the sample of csv page:
```csv
0,backend,106.187.48.116:80,up,46,0,http,80
```
Below it's the sample of json page:
```json
{
    "servers": {
        "total": 1,
        "generation": 3,
        "server": [
            {
                "index": 0,
                "upstream": "backend",
                "name": "106.187.48.116:80",
                "status": "up",
                "rise": 58,
                "fall": 0,
                "type": "http",
                "port": 80
            }
        ]
    }
}
```
## Installation
### 1. ​Download the module:
```bash
git clone https://github.com/mofantor/nginx_upstream_check_module.git
```
### 2. Download and patch Nginx:
```bash
wget http://nginx.org/download/nginx-1.26.3.tar.gz
tar -xzvf nginx-1.26.3.tar.gz
cd nginx-1.26.3/
patch -p1 < ../nginx_upstream_check_module/check_1.26.3+.patch
```

### 3. ​Compile and install:
```bash
./configure --add-module=../nginx_upstream_check_module
make
sudo make install
```

## Compatibility Notes
| Nginx Version | Required Patch |
| ----------- | ----------- |
| 1.2.1 | check_1.2.1.patch |
| 1.2.2+ | check_1.2.2+.patch |
| 1.2.6+ | check_1.2.6+.patch |
| 1.5.12+ | check_1.5.12+.patch |
| 1.7.2+ | check_1.7.2+.patch |
| 1.7.5+ | check_1.7.5+.patch |
| 1.9.2+ | check_1.9.2+.patch |
| 1.11.1+ | check_1.11.1+.patch |
| 1.11.5+ | check_1.11.5+.patch |
| 1.12.1+ | check_1.12.1+.patch |
| 1.14.0+ | check_1.14.0+.patch |
| 1.16.1+ | check_1.16.1+.patch |
| 1.20.1+ | check_1.20.1+.patch |
| 1.26.3+ | check_1.26.3+.patch |



## Authors
+ Weibin Yao(姚伟斌) （yaoweibin@gmail.com)
+ Matthieu Tourne

    

## Copyright & License
```license
This README template copy from agentzh (<http://github.com/agentzh>).

The health check part is borrowed the design of Jack Lindamood's
healthcheck module healthcheck_nginx_upstreams
(<http://github.com/cep21/healthcheck_nginx_upstreams>);

This module is licensed under the BSD license.

Copyright (C) 2014 by Weibin Yao <yaoweibin@gmail.com>

Copyright (C) 2010-2014 Alibaba Group Holding Limited

Copyright (C) 2014 by LiangBin Li

Copyright (C) 2014 by Zhuo Yuan

Copyright (C) 2012 by Matthieu Tourne

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

*   Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

*   Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
