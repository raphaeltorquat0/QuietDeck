# Servidor do acervo para os testes: SSH, SMB e o serviço da Estante sobre a mesma pasta.
FROM alpine:3.22
RUN apk add --no-cache openssh rsync python3 samba \
 && adduser -D -s /bin/sh acervo && echo 'acervo:acervo-password' | chpasswd && ssh-keygen -A \
 && printf 'acervo-password\nacervo-password\n' | smbpasswd -a -s acervo
COPY smb.conf /etc/samba/smb.conf
COPY entrypoint.sh /usr/local/bin/
COPY --from=service shelf-service.py folders.txt /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh
EXPOSE 22 445 8766
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
